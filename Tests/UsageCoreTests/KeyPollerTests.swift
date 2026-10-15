import Foundation
import Testing
import UsageCore

/// An obviously fake key: every test checks it never leaves the store except
/// in the `Authorization` header.
let fakeKey = "fake-key-DO-NOT-USE-1234567890"

/// A key provider for tests: one GET to its balance endpoint, which answers
/// `{"balance": "12.40", "limit": 20}`.
enum TestKeyAPI: KeyAPI {
    static let id = "testkey"
    static let name = "Test Key"
    static let symbol = "T"
    static let systemImage = "key"
    static let hosts: Set<String> = ["api.example.com"]
    static let endpoint = URL(string: "https://api.example.com/v1/balance")!

    struct Reading: Equatable, Sendable {
        var balance: Double?
        var limit: Double?
    }

    static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let balance = (object["balance"] as? String).flatMap(Double.init) ?? (object["balance"] as? Double)
        let limit = object["limit"] as? Double
        return balance == nil && limit == nil ? nil : Reading(balance: balance, limit: limit)
    }

    static func report(_ reading: Reading?, clock: Clock) -> ProviderReport {
        ProviderReport(rows: [
            .credit(CreditRow(id: "testkey.credit", label: "Credit", left: reading?.balance.map { Amount($0, .usd) },
                              of: reading?.limit.map { Amount($0, .usd) })),
        ])
    }

    static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading { reading }
}

/// A key provider whose endpoint isn't on its declared host.
enum OffHostAPI: KeyAPI {
    static let id = "offhost"
    static let name = "Off Host"
    static let symbol = "O"
    static let systemImage = "key"
    static let hosts: Set<String> = ["api.example.com"]
    static let endpoint = URL(string: "https://collector.example.net/v1/balance")!
    typealias Reading = TestKeyAPI.Reading
    static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? { TestKeyAPI.reading(fromResponse: body, receivedAt: receivedAt) }
    static func report(_ reading: Reading?, clock: Clock) -> ProviderReport { TestKeyAPI.report(reading, clock: clock) }
    static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading { reading }
}

/// A key provider that tries a plain-HTTP URL, a look-alike host and its
/// own Authorization header before the real request.
enum SneakyAPI: KeyAPI {
    static let id = "sneaky"
    static let name = "Sneaky"
    static let symbol = "S"
    static let systemImage = "key"
    static let hosts: Set<String> = ["api.example.com"]
    static let endpoint = URL(string: "https://api.example.com/v1/balance")!
    typealias Reading = TestKeyAPI.Reading
    static func fetch(_ client: KeyClient) async -> PollOutcome {
        for url in ["http://api.example.com/v1/balance", "https://api.example.com.evil.net/v1", "https://user@api.example.com/v1",
                    "https://api.example.com:8443/v1"] {
            if case .response = await client.get(URL(string: url)!) { return .response(status: 599, body: Data()) }
        }
        if case .response = await client.get(endpoint, headers: ["Authorization": "Bearer other"]) { return .response(status: 599, body: Data()) }
        return await client.get(URL(string: "https://API.EXAMPLE.COM/v1/balance")!)
    }
    static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? { TestKeyAPI.reading(fromResponse: body, receivedAt: receivedAt) }
    static func report(_ reading: Reading?, clock: Clock) -> ProviderReport { TestKeyAPI.report(reading, clock: clock) }
    static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading { reading }
}

/// Keys in memory: the user's Keychain is never touched by tests.
final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    private(set) var reads = 0

    init(_ keys: [String: String] = [:]) {
        self.keys = keys
    }

    func key(for id: String) async throws -> String? {
        lock.withLock {
            reads += 1
            return keys[id]
        }
    }

    func hasKey(for id: String) -> Bool {
        lock.withLock { keys[id] != nil }
    }

    func save(_ key: String, for id: String) throws {
        lock.withLock { keys[id] = key }
    }

    func removeKey(for id: String) throws {
        lock.withLock { keys[id] = nil }
    }
}

/// Records every request and answers from a script, then with the last answer.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [PollOutcome]
    private(set) var requests: [URLRequest] = []

    init(_ answers: PollOutcome...) {
        self.answers = answers
    }

    func answer(_ outcomes: PollOutcome...) {
        lock.withLock { answers = outcomes }
    }

    func send(_ request: URLRequest) async -> PollOutcome {
        lock.withLock {
            requests.append(request)
            return answers.count > 1 ? answers.removeFirst() : answers.first ?? .networkError
        }
    }
}

/// Holds each request until the test releases it.
final class GateTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<PollOutcome, Never>?
    private var count = 0
    var requests: Int { lock.withLock { count } }

    func send(_ request: URLRequest) async -> PollOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock {
                count += 1
                waiting = continuation
            }
        }
    }

    func release(_ outcome: PollOutcome) {
        lock.withLock { waiting }?.resume(returning: outcome)
    }
}

/// Holds each key read until the test releases it, then answers with the
/// key that was saved when the read began.
final class GateKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = 0
    private var count = 0
    var reads: Int { lock.withLock { count } }

    init(_ keys: [String: String]) {
        self.keys = keys
    }

    func key(for id: String) async throws -> String? {
        let value = lock.withLock { () -> String? in
            count += 1
            return keys[id]
        }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released > 0 {
                    released -= 1
                    return true
                }
                waiting = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return value
    }

    func hasKey(for id: String) -> Bool { lock.withLock { keys[id] != nil } }
    func save(_ key: String, for id: String) throws { lock.withLock { keys[id] = key } }
    func removeKey(for id: String) throws { lock.withLock { keys[id] = nil } }

    /// Lets the pending read (or the next one) finish.
    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let waiting else {
                released += 1
                return nil
            }
            self.waiting = nil
            return waiting
        }
        continuation?.resume()
    }
}

/// A clock the test moves by hand.
@MainActor
final class FakeClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

let goodBody = Data(#"{"balance": "12.40", "limit": 20}"#.utf8)

@MainActor
@Suite("Key poller")
struct KeyPollerTests {
    let clock = FakeClock(now)
    var lines: [String] { log.lines }
    let log = LogSink()

    final class LogSink: @unchecked Sendable {
        var lines: [String] = []
    }

    func poller<API: KeyAPI>(
        _ api: API.Type = TestKeyAPI.self, store: MemoryKeyStore = MemoryKeyStore(["testkey": fakeKey, "offhost": fakeKey, "sneaky": fakeKey]),
        transport: some HTTPTransport
    ) -> KeyPoller<API> {
        let clock = clock
        let log = log
        return KeyPoller<API>(store: store, transport: transport, now: { clock.now }, log: { log.lines.append($0) })
    }

    func section<API: KeyAPI>(_ poller: KeyPoller<API>) throws -> ProviderSection {
        try #require(UsageEngine.snapshot(from: Readings([poller.provider]), now: clock.now, timeZone: losAngeles)[API.id])
    }

    func creditText(_ section: ProviderSection) -> String? {
        if case let .credit(meter) = section.rows.first { meter.valueText } else { nil }
    }

    // MARK: Answers

    @Test("a good answer fills the rows and the updated time")
    func goodAnswer() async throws {
        let poller = poller(transport: FakeTransport(.response(status: 200, body: goodBody)))
        await poller.poll(.timer)
        let section = try section(poller)
        #expect(creditText(section) == "$12.40 left of $20")
        #expect(section.updatedText == "Updated just now")
        #expect(section.note == nil)
    }

    @Test("a 401 or 403 reads \"Key rejected\" with dashes, and the key is read from the store again next time", arguments: [401, 403])
    func rejected(status: Int) async throws {
        let store = MemoryKeyStore(["testkey": fakeKey])
        let transport = FakeTransport(.response(status: 200, body: goodBody), .response(status: status, body: Data()))
        let poller = poller(store: store, transport: transport)
        await poller.poll(.timer)
        clock.now += 300
        await poller.poll(.timer)
        let section = try section(poller)
        #expect(creditText(section) == "—")
        #expect(section.note == "Key rejected")
        #expect(store.reads == 1)
        clock.now += 300
        await poller.poll(.timer)
        #expect(store.reads == 2)
    }

    @Test("network errors, 429 and 5xx keep the last good reading", arguments: [
        PollOutcome.networkError, .response(status: 429, body: Data()), .response(status: 503, body: Data("<html>".utf8)),
    ])
    func transientFailure(outcome: PollOutcome) async throws {
        let poller = poller(transport: FakeTransport(.response(status: 200, body: goodBody), outcome))
        await poller.poll(.timer)
        clock.now += 300
        await poller.poll(.timer)
        let section = try section(poller)
        #expect(creditText(section) == "$12.40 left of $20")
        #expect(section.updatedText == "Updated 5 min ago")
        #expect(section.note == nil)
    }

    @Test("a changed or unreadable answer turns the rows into dashes")
    func unreadable() async throws {
        let poller = poller(transport: FakeTransport(.response(status: 200, body: goodBody), .response(status: 200, body: Data(#"{"renamed": 1}"#.utf8))))
        await poller.poll(.timer)
        clock.now += 300
        await poller.poll(.timer)
        let section = try section(poller)
        #expect(creditText(section) == "—")
        #expect(section.note == "Couldn't read the answer from api.example.com")
    }

    @Test("another HTTP error turns the rows into dashes and says so")
    func otherError() async throws {
        let poller = poller(transport: FakeTransport(.response(status: 404, body: Data())))
        await poller.poll(.timer)
        let section = try section(poller)
        #expect(creditText(section) == "—")
        #expect(section.note == "api.example.com answered HTTP 404")
    }

    @Test("with no key saved nothing is sent")
    func noKey() async throws {
        let transport = FakeTransport(.response(status: 200, body: goodBody))
        let poller = poller(store: MemoryKeyStore(), transport: transport)
        await poller.poll(.timer)
        #expect(transport.requests.isEmpty)
        #expect(try section(poller).note == "No API key saved")
    }

    // MARK: Where the key goes

    @Test("the key goes only in the Authorization header of an https request to the provider's host")
    func keyOnlyInAuthorization() async throws {
        let transport = FakeTransport(.response(status: 200, body: goodBody))
        let poller = poller(transport: transport)
        await poller.poll(.timer)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url == TestKeyAPI.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")
        let otherHeaders = (request.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased() != "authorization" }
        #expect(!otherHeaders.description.contains(fakeKey))
        #expect(!(request.url?.absoluteString.contains(fakeKey) ?? true))
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("a request to any other host is blocked before it's sent")
    func offHost() async throws {
        let transport = FakeTransport(.response(status: 200, body: goodBody))
        let poller = poller(OffHostAPI.self, transport: transport)
        await poller.poll(.timer)
        #expect(transport.requests.isEmpty)
        #expect(try section(poller).note == "Blocked a request outside api.example.com")
    }

    @Test("plain HTTP, look-alike hosts, user info, other ports and a provider's own Authorization header are all blocked")
    func sneaky() async throws {
        let transport = FakeTransport(.response(status: 200, body: goodBody))
        let poller = poller(SneakyAPI.self, transport: transport)
        await poller.poll(.timer)
        #expect(transport.requests.map { $0.url?.absoluteString } == ["https://API.EXAMPLE.COM/v1/balance"])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")
        #expect(creditText(try section(poller)) == "$12.40 left of $20")
    }

    @Test("the key never appears in the log, the provider's readings, the snapshot or the saved alert memory")
    func keyNeverLeaks() async throws {
        let transport = FakeTransport(
            .response(status: 200, body: goodBody), .response(status: 401, body: Data(fakeKey.utf8)), .response(status: 503, body: Data()),
            .networkError, .response(status: 200, body: Data("not json".utf8)), .response(status: 418, body: Data())
        )
        let poller = poller(transport: transport)
        let blocked = self.poller(OffHostAPI.self, transport: transport)
        var dumps: [String] = []
        for _ in 0..<6 {
            await poller.poll(.timer)
            await blocked.poll(.timer)
            let snapshot = UsageEngine.snapshot(from: Readings([poller.provider, blocked.provider]), now: clock.now, timeZone: losAngeles)
            var dump = ""
            Swift.dump(poller.provider, to: &dump)
            Swift.dump(snapshot, to: &dump)
            dumps += [dump, String(decoding: snapshot.alertMemory.encoded(), as: UTF8.self)]
            clock.now += 3600
        }
        #expect(lines.count >= 12)
        for text in lines + dumps {
            #expect(!text.contains(fakeKey))
            #expect(!text.contains("Bearer"))
        }
    }

    // MARK: When to ask

    /// The first second from now when `trigger` polls, up to two hours on.
    func due<API: KeyAPI>(_ poller: KeyPoller<API>, _ trigger: PollTrigger) -> TimeInterval? {
        (0...(2 * 3600)).lazy.map(TimeInterval.init).first { poller.isDue(trigger, at: clock.now + $0) }
    }

    @Test("the timer polls every 5 minutes, the popover at most once a minute")
    func cadence() async {
        let transport = FakeTransport(.response(status: 200, body: goodBody))
        let poller = poller(transport: transport)
        #expect(await poller.poll(.popover))
        #expect(due(poller, .timer) == 300)
        #expect(due(poller, .popover) == 60)
        clock.now += 59
        #expect(await poller.poll(.popover) == false)
        #expect(await poller.poll(.timer) == false)
        clock.now += 1
        #expect(await poller.poll(.popover))
        #expect(transport.requests.count == 2)
    }

    @Test("429, 5xx and network errors back off 10 minutes doubling to an hour; a good answer ends it")
    func backoff() async {
        let transport = FakeTransport(.response(status: 429, body: Data()))
        let poller = poller(transport: transport)
        var waits: [TimeInterval?] = []
        for outcome in [PollOutcome.response(status: 429, body: Data()), .response(status: 500, body: Data()), .networkError, .response(status: 502, body: Data()), .networkError] {
            transport.answer(outcome)
            await poller.poll(.timer)
            let wait = due(poller, .popover)
            #expect(due(poller, .timer) == wait)
            waits.append(wait)
            clock.now += wait ?? 0
        }
        #expect(waits == [600, 1200, 2400, 3600, 3600])
        transport.answer(.response(status: 200, body: goodBody))
        await poller.poll(.timer)
        #expect(due(poller, .timer) == 300)
        #expect(due(poller, .popover) == 60)
    }

    @Test("a Retry-After longer than the backoff is honoured, up to an hour")
    func retryAfter() async {
        let poller = poller(transport: FakeTransport(.response(status: 429, body: Data(), retryAfter: 1800)))
        await poller.poll(.timer)
        #expect(due(poller, .popover) == 1800)
    }

    @Test("a rejected key keeps the normal schedule rather than backing off")
    func rejectedSchedule() async {
        let poller = poller(transport: FakeTransport(.response(status: 401, body: Data())))
        await poller.poll(.timer)
        #expect(due(poller, .timer) == 300)
    }

    @Test("a new key polls at once, even while backing off")
    func keyChanged() async {
        let transport = FakeTransport(.response(status: 503, body: Data()))
        let poller = poller(transport: transport)
        await poller.poll(.timer)
        poller.keyChanged()
        #expect(due(poller, .popover) == 0)
    }

    @Test("an answer that arrives after stop() is dropped")
    func stopDropsAnswer() async throws {
        let transport = GateTransport()
        let poller = poller(transport: transport)
        let task = Task { await poller.poll(.timer) }
        while transport.requests == 0 { await Task.yield() }
        poller.stop()
        transport.release(.response(status: 200, body: goodBody))
        await task.value
        #expect(poller.provider == KeyProvider<TestKeyAPI>())
        #expect(lines.isEmpty)
    }

    @Test("a key read that finishes after the key changed isn't kept: the next poll sends the new key")
    func staleKeyRead() async throws {
        let store = GateKeyStore(["testkey": fakeKey])
        let transport = FakeTransport(.response(status: 200, body: goodBody))
        let poller = KeyPoller<TestKeyAPI>(store: store, transport: transport, now: { [clock] in clock.now })
        let first = Task { await poller.poll(.timer) }
        while store.reads == 0 { await Task.yield() }
        try store.save("fake-key-replacement", for: "testkey")
        poller.keyChanged()
        store.release()
        await first.value
        #expect(transport.requests.isEmpty)

        let second = Task { await poller.poll(.timer) }
        while store.reads < 2, transport.requests.isEmpty { await Task.yield() }
        store.release()
        await second.value
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer fake-key-replacement"])
    }

    // MARK: Test connection

    @Test("Test connection tries the typed key without saving it or changing the rows", arguments: [
        (PollOutcome.response(status: 200, body: goodBody), ConnectionTest.connected),
        (.response(status: 401, body: Data()), .rejected),
        (.networkError, .unreachable("api.example.com")),
        (.response(status: 503, body: Data()), .failed("api.example.com answered HTTP 503")),
        (.response(status: 200, body: Data("{}".utf8)), .failed("Couldn't read the answer from api.example.com")),
    ])
    func testConnection(outcome: PollOutcome, result: ConnectionTest) async throws {
        let store = MemoryKeyStore()
        let transport = FakeTransport(outcome)
        let poller = poller(store: store, transport: transport)
        #expect(await poller.testConnection(key: "  typed-fake-key\n") == result)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer typed-fake-key")
        #expect(!store.hasKey(for: "testkey"))
        #expect(poller.provider == KeyProvider<TestKeyAPI>())
    }

    @Test("Test connection with nothing typed uses the saved key, or says there's none")
    func testSavedKey() async {
        let transport = FakeTransport(.response(status: 200, body: goodBody))
        #expect(await poller(transport: transport).testConnection(key: nil) == .connected)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")
        #expect(await poller(store: MemoryKeyStore(), transport: transport).testConnection(key: "") == .noKey)
    }

    @Test("a key with spaces around it is trimmed; one with control characters or spaces inside is refused", arguments: [
        ("  sk-fake-123 \n", "sk-fake-123"), ("", nil), ("   ", nil), ("fake\nkey", nil), ("fake key", nil), ("fake\u{7F}key", nil), ("fakeé", nil),
    ] as [(String, String?)])
    func keyNormalizing(input: String, key: String?) {
        #expect(APIKey.normalized(input) == key)
    }
}
