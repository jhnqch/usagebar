import Foundation

// MARK: - What a key provider implements

/// An API that UsageBar reads with the user's own API key: OpenRouter,
/// DeepSeek, Moonshot and the like. This is all a new key provider writes:
/// where its endpoint is, how to read an answer, and what rows to show.
/// `KeyProvider` makes it a `Provider`; `KeyPoller` polls it, keeps the key
/// on its hosts and applies the error and back-off policy; the Providers
/// menu gives it a key window.
///
/// ```swift
/// enum DeepSeekAPI: KeyAPI {
///     static let id = "deepseek", name = "DeepSeek", symbol = "◈", systemImage = "fish"
///     static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
///     struct Reading: Equatable, Sendable { var balances: [Amount] }
///     static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? { … }
///     static func report(_ reading: Reading?, clock: Clock) -> ProviderReport { … }
///     static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading { reading }
/// }
/// ```
public protocol KeyAPI: Sendable {
    /// What one good answer says, decoded tolerantly.
    associatedtype Reading: Equatable, Sendable

    /// Stable and unique: "openrouter". Names its Keychain item, its
    /// settings and its fixtures key, so it must never change.
    static var id: String { get }
    /// "OpenRouter".
    static var name: String { get }
    /// A short menu bar glyph.
    static var symbol: String { get }
    /// The SF Symbol beside the section's title.
    static var systemImage: String { get }

    /// The request polled. Must be https on one of `hosts`.
    static var endpoint: URL { get }
    /// The only hosts the key is ever sent to. Defaults to the endpoint's.
    static var hosts: Set<String> { get }
    /// The `Authorization` header's value for `key`. Defaults to
    /// `Bearer <key>`.
    static func authorization(key: String) -> String
    /// One poll: by default a GET of `endpoint`. A provider that needs more
    /// than one request overrides it; every request goes through `client`,
    /// which adds the key and refuses any other host.
    static func fetch(_ client: KeyClient) async -> PollOutcome

    /// A 200 answer as a reading; nil when nothing in it is readable. A
    /// missing, renamed or mistyped field should leave only its own part of
    /// the reading nil.
    static func reading(fromResponse body: Data, receivedAt: Date) -> Reading?
    /// The section's rows for a reading. With nil the rows are still there
    /// and show "—". Plan, note and chart are optional; the updated time
    /// and error notes are filled in for it.
    static func report(_ reading: Reading?, clock: Clock) -> ProviderReport
    /// The reading moved `offset` seconds later, for fixtures rebased to a
    /// new "now": shift every date in it.
    static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading

    /// Where to get a key, shown in the key window: "openrouter.ai/settings/keys".
    static var keyHint: String? { get }
}

extension KeyAPI {
    public static var hosts: Set<String> { [endpoint.host?.lowercased()].compactMap(\.self).reduce(into: []) { $0.insert($1) } }
    public static func authorization(key: String) -> String { "Bearer \(key)" }
    public static func fetch(_ client: KeyClient) async -> PollOutcome { await client.get(endpoint) }
    public static var keyHint: String? { nil }

    /// What the Providers menu and detection know about it: a key
    /// provider, shown once its key is saved.
    public static var info: ProviderInfo { ProviderInfo(id: id, name: name, usesKey: true) }

    /// The provider with no readings yet, for the app's starting readings.
    public static var emptyProvider: any Provider { KeyProvider<Self>() }

    /// The provider's type, for the list of providers fixtures decode.
    public static var providerType: any Provider.Type { KeyProvider<Self>.self }

    /// The endpoint's host, for notes: "openrouter.ai".
    static var hostText: String { endpoint.host ?? hosts.sorted().joined(separator: ", ") }
}

// MARK: - Where the key may go

/// Sends a request once and never follows a redirect: a 3xx comes back as
/// the answer, so the `Authorization` header can't be carried to another
/// host. The app's is a `URLSession` with nothing kept on disk; tests use a
/// fake.
public protocol HTTPTransport: Sendable {
    /// `.response` or `.networkError`.
    func send(_ request: URLRequest) async -> PollOutcome
}

/// What a key provider's `fetch` makes its requests with. It holds the key
/// and adds it as the `Authorization` header, and only to an https URL on
/// one of the provider's hosts, on the default port, without user info. A
/// request anywhere else comes back `.blocked` without being sent. The key
/// itself is never exposed.
public struct KeyClient: Sendable {
    private let key: String
    private let hosts: Set<String>
    private let authorization: String
    private let userAgent: String
    private let transport: any HTTPTransport

    init<API: KeyAPI>(_ api: API.Type, key: String, transport: any HTTPTransport, userAgent: String) {
        self.key = key
        hosts = Set(API.hosts.map { $0.lowercased() })
        authorization = API.authorization(key: key)
        self.userAgent = userAgent
        self.transport = transport
    }

    /// GETs `url` with the key. `headers` may add anything but
    /// `Authorization`, `Cookie` or `Proxy-Authorization`.
    public func get(_ url: URL, headers: [String: String] = [:]) async -> PollOutcome {
        guard url.scheme?.lowercased() == "https" else { return .blocked("not https: \(url.host ?? "no host")") }
        guard let host = url.host?.lowercased(), hosts.contains(host) else {
            return .blocked("\(url.host ?? "no host") isn't \(hosts.sorted().joined(separator: " or "))")
        }
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            return .blocked("user info or another port on \(host)")
        }
        let reserved: Set = ["authorization", "cookie", "proxy-authorization"]
        guard !headers.keys.contains(where: { reserved.contains($0.lowercased()) }) else {
            return .blocked("a provider can't set its own credentials header")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return await transport.send(request)
    }
}

// MARK: - Where the key is kept

/// Where API keys are saved: UsageBar's own Keychain items in the app, one
/// per provider; memory in tests. Nothing else ever holds a key.
public protocol KeyStore: Sendable {
    /// The saved key, or nil. May show a Keychain prompt, so it's async.
    func key(for id: String) async throws -> String?
    /// Whether a key is saved, without reading it (so without a prompt).
    func hasKey(for id: String) -> Bool
    /// Saves `key`, replacing any saved one. `key` is already normalized.
    func save(_ key: String, for id: String) throws
    func removeKey(for id: String) throws
}

/// What the user typed as a key.
public enum APIKey {
    /// The key with surrounding spaces and newlines trimmed, or nil when
    /// it's empty or has anything but printable ASCII inside (a space, a
    /// control character, non-ASCII), which no provider's keys do and which
    /// could split the header.
    public static func normalized(_ input: String) -> String? {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return key
    }
}

// MARK: - The provider

/// Why a key provider's rows show "—", as its section's note.
public enum KeyProblem: Equatable, Sendable {
    /// 401 or 403.
    case rejected
    /// No key saved.
    case noKey
    /// A 200 with nothing readable: the format changed.
    case unreadable
    /// Another HTTP status.
    case http(Int)
    /// The provider tried to send the key elsewhere.
    case blocked
}

/// A key provider as the engine sees it: its API and its latest reading.
public struct KeyProvider<API: KeyAPI>: Provider {
    public var id: String { API.id }
    public var name: String { API.name }
    public var symbol: String { API.symbol }
    public var systemImage: String { API.systemImage }

    /// The latest good reading; nil shows the rows as "—".
    public var reading: API.Reading?
    /// When `reading` arrived.
    public var capturedAt: Date?
    /// Why there's no reading, if known.
    public var problem: KeyProblem?

    public init(reading: API.Reading? = nil, capturedAt: Date? = nil, problem: KeyProblem? = nil) {
        self.reading = reading
        self.capturedAt = capturedAt
        self.problem = problem
    }

    public func report(clock: Clock) -> ProviderReport {
        var report = API.report(reading, clock: clock)
        if reading != nil, report.updatedAt == nil {
            report.updatedAt = capturedAt
        }
        if let problem {
            report.note = Self.note(problem)
        }
        return report
    }

    static func note(_ problem: KeyProblem) -> String {
        switch problem {
        case .rejected: "Key rejected"
        case .noKey: "No API key saved"
        case .unreadable: "Couldn't read the answer from \(API.hostText)"
        case let .http(status): "\(API.hostText) answered HTTP \(status)"
        case .blocked: "Blocked a request outside \(API.hosts.sorted().joined(separator: ", "))"
        }
    }

    public func shifted(by offset: TimeInterval) -> KeyProvider {
        KeyProvider(reading: reading.map { API.shift($0, by: offset) }, capturedAt: capturedAt.map { $0 + offset }, problem: problem)
    }

    /// From a fixture: the recorded answers under its id, replayed in order
    /// through the same policy as the app's polls. Absent when the fixture
    /// has none, so fixtures without it show no section for it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let polls = try c.decode([Lenient<RecordedPoll>].self, forKey: AnyKey(API.id)).compactMap(\.value)
        var polling = KeyPolling<API>()
        for poll in polls {
            polling.start(at: poll.receivedAt)
            polling.finish(poll.outcome, at: poll.receivedAt)
        }
        self = polling.provider
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - The policy

/// What each answer does to a key provider's reading, and when to ask
/// again. Pure; `KeyPoller` runs it.
///
/// - 200 with something readable replaces the reading; with nothing
///   readable it drops it ("Couldn't read the answer").
/// - 401 or 403 drops it ("Key rejected"), and the key is read from the
///   store again next time.
/// - Network errors, 429 and 5xx keep the last reading and back off, 10
///   minutes doubling to an hour (or as long as `Retry-After` says, up to an
///   hour).
/// - Any other status, no key, or a blocked request drops it.
struct KeyPolling<API: KeyAPI>: Sendable {
    private(set) var provider = KeyProvider<API>()
    private var schedule = PollSchedule()

    struct Finished {
        /// Read the key from the store again before the next request.
        var forgetKey = false
        /// One line for the log: never the key or the body.
        var summary: String
    }

    func isDue(_ trigger: PollTrigger, at now: Date) -> Bool {
        schedule.isDue(trigger, at: now)
    }

    mutating func start(at now: Date) {
        schedule.start(at: now)
    }

    /// The next poll is due at once.
    mutating func reset() {
        schedule.reset()
    }

    @discardableResult
    mutating func finish(_ outcome: PollOutcome, at now: Date) -> Finished {
        switch outcome {
        case let .response(200, body, _):
            schedule.endBackoff()
            if let reading = API.reading(fromResponse: body, receivedAt: now) {
                provider = KeyProvider(reading: reading, capturedAt: now)
                return Finished(summary: "HTTP 200")
            }
            provider = KeyProvider(problem: .unreadable)
            return Finished(summary: "HTTP 200 with nothing readable")
        case let .response(status, _, _) where status == 401 || status == 403:
            schedule.endBackoff()
            provider = KeyProvider(problem: .rejected)
            return Finished(forgetKey: true, summary: "HTTP \(status): key rejected")
        case let .response(status, _, retryAfter) where status == 429 || (500...599).contains(status):
            let wait = schedule.backOff(at: now, retryAfter: retryAfter)
            return Finished(summary: "HTTP \(status): keeping the last reading, next try in \(Int(wait / 60)) min")
        case .networkError:
            let wait = schedule.backOff(at: now, retryAfter: nil)
            return Finished(summary: "network error: keeping the last reading, next try in \(Int(wait / 60)) min")
        case let .response(status, _, _):
            schedule.endBackoff()
            provider = KeyProvider(problem: .http(status))
            return Finished(summary: "HTTP \(status)")
        case .noCredentials:
            schedule.endBackoff()
            provider = KeyProvider(problem: .noKey)
            return Finished(summary: "no key saved")
        case let .blocked(reason):
            schedule.endBackoff()
            provider = KeyProvider(problem: .blocked)
            return Finished(summary: "blocked a request: \(reason)")
        }
    }
}

// MARK: - The poller

/// What "Test connection" found.
public enum ConnectionTest: Equatable, Sendable {
    case connected
    case rejected
    /// Nothing typed and no key saved.
    case noKey
    /// What was typed can't be a key.
    case invalidKey
    case unreachable(String)
    case failed(String)

    /// The line under the key field.
    public var text: String {
        switch self {
        case .connected: "Connected"
        case .rejected: "Key rejected"
        case .noKey: "Type a key to test"
        case .invalidKey: "That doesn't look like a key"
        case let .unreachable(host): "Couldn't reach \(host)"
        case let .failed(reason): reason
        }
    }
}

/// Polls one key provider: every 5 minutes on the timer, and when the
/// popover opens at most once a minute, with `KeyPolling`'s answers and
/// back-off. Reads the key from the store when it needs it and keeps it in
/// memory only, until it's rejected, changed or the poller stops. The key
/// goes only to `KeyClient`, so only into the `Authorization` header of
/// requests to the provider's hosts. Log lines never hold it.
@MainActor
public final class KeyPoller<API: KeyAPI> {
    /// The latest readings, for `AppModel.update`.
    public private(set) var provider = KeyProvider<API>()

    private var polling = KeyPolling<API>()
    private var key: String?
    private var inFlight = false
    /// Bumped by `stop()` and `keyChanged()`: an answer to a request from an
    /// earlier generation is dropped.
    private var generation = 0
    private let store: any KeyStore
    private let transport: any HTTPTransport
    private let userAgent: String
    private let now: () -> Date
    private let log: (String) -> Void

    public init(
        store: any KeyStore,
        transport: any HTTPTransport,
        userAgent: String = "UsageBar",
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.transport = transport
        self.userAgent = userAgent
        self.now = now
        self.log = log
    }

    public func isDue(_ trigger: PollTrigger, at time: Date) -> Bool {
        polling.isDue(trigger, at: time)
    }

    /// Polls if one is due and none is under way. Returns whether it did.
    @discardableResult
    public func poll(_ trigger: PollTrigger) async -> Bool {
        guard !inFlight, polling.isDue(trigger, at: now()) else { return false }
        inFlight = true
        let generation = generation
        defer {
            if generation == self.generation { inFlight = false }
        }
        polling.start(at: now())

        if key == nil {
            key = try? await store.key(for: API.id)
            guard generation == self.generation else { return true }
        }
        let outcome: PollOutcome = if let key {
            await API.fetch(KeyClient(API.self, key: key, transport: transport, userAgent: userAgent))
        } else {
            .noCredentials
        }
        guard generation == self.generation else { return true }

        let finished = polling.finish(outcome, at: now())
        if finished.forgetKey {
            key = nil
        }
        provider = polling.provider
        log("\(API.name): \(finished.summary)")
        return true
    }

    /// The key was saved or removed: forget the one in memory, drop any
    /// answer under way, and poll at once.
    public func keyChanged() {
        key = nil
        generation += 1
        inFlight = false
        polling.reset()
    }

    /// The provider was turned off: forget the key and drop any answer
    /// under way.
    public func stop() {
        key = nil
        generation += 1
        inFlight = false
    }

    /// Tries `typed` (or, with nothing typed, the saved key) against the
    /// endpoint. Saves nothing and leaves the readings alone.
    public func testConnection(key typed: String?) async -> ConnectionTest {
        let candidate: String
        if let typed, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let key = APIKey.normalized(typed) else { return .invalidKey }
            candidate = key
        } else if let saved = try? await store.key(for: API.id) {
            candidate = saved
        } else {
            return .noKey
        }
        let outcome = await API.fetch(KeyClient(API.self, key: candidate, transport: transport, userAgent: userAgent))
        switch outcome {
        case let .response(200, body, _):
            return API.reading(fromResponse: body, receivedAt: now()) == nil
                ? .failed(KeyProvider<API>.note(.unreadable)) : .connected
        case let .response(status, _, _) where status == 401 || status == 403:
            return .rejected
        case let .response(status, _, _):
            return .failed(KeyProvider<API>.note(.http(status)))
        case .networkError:
            return .unreachable(API.hostText)
        case .noCredentials:
            return .noKey
        case .blocked:
            return .failed(KeyProvider<API>.note(.blocked))
        }
    }
}
