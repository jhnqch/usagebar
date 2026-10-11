import Foundation

/// When UsageBar asks Claude's usage endpoint, and what each answer does to
/// the endpoint's reading. Pure: the app's adapter reads the Keychain, makes
/// the request and reports the outcome.
///
/// - A good answer replaces the reading.
/// - A refused login (401, 403) drops it until Claude Code refreshes its
///   login; the next poll reads the token from the Keychain again. UsageBar
///   never refreshes the token itself.
/// - Busy (429) or down (5xx) answers and network errors keep the last good
///   reading.
/// - Anything else (another HTTP error, a body with nothing readable, no
///   saved login) drops it.
///
/// Without a reading, only the Fable meter shows "—": the 5-hour and weekly
/// meters still have the status line.
///
/// The endpoint is rate-limited, so UsageBar asks every 5 minutes, and when
/// the popover opens at most once a minute. After a 429 or 5xx (or no saved
/// login, so a denied Keychain prompt doesn't come straight back) it backs
/// off, doubling from 10 minutes up to an hour, or longer if `Retry-After`
/// says so (also up to an hour).
public struct ClaudeUsagePolling: Sendable {
    public static let interval: TimeInterval = 5 * 60
    public static let minimumGap: TimeInterval = 60
    static let maximumBackoff: TimeInterval = 60 * 60

    /// What asks for a poll.
    public enum Trigger: Sendable {
        /// The regular timer: every 5 minutes.
        case timer
        /// Opening the popover, Refresh, waking from sleep: at most once a minute.
        case popover
    }

    /// What came of one request.
    public enum Outcome: Equatable, Sendable {
        /// An HTTP answer. `retryAfter` is the `Retry-After` header in seconds.
        case response(status: Int, body: Data, retryAfter: TimeInterval? = nil)
        /// No answer: offline, timed out, TLS failure.
        case networkError
        /// No access token in the Keychain (not logged in, item missing,
        /// access denied).
        case noCredentials
    }

    /// What the adapter does after a request.
    public struct Finished: Equatable, Sendable {
        /// The token was refused: read it from the Keychain again before the
        /// next request.
        public var rereadToken = false
        /// One line for the log. Never holds the token or the response.
        public var summary: String
    }

    /// The endpoint's latest reading; nil shows Fable as "—".
    public private(set) var reading: ClaudeLimits?
    private var lastStart: Date?
    /// While backing off, no poll before this.
    private var notBefore: Date?
    /// Backoffs in a row, for the doubling.
    private var backoffs = 0

    public init() {}

    /// Whether to ask the endpoint now.
    public func isDue(_ trigger: Trigger, at now: Date) -> Bool {
        guard let lastStart else { return true }
        // A clock set back makes every deadline taken from the old clock
        // meaningless, the backoff's included: poll, and start over from now.
        guard now >= lastStart else { return true }
        if let notBefore, now < notBefore { return false }
        return now.timeIntervalSince(lastStart) >= (trigger == .timer ? Self.interval : Self.minimumGap)
    }

    /// Notes that a request starts now. Any backoff is over (or its deadline
    /// came from a clock since set back); the answer may start a new one.
    public mutating func start(at now: Date) {
        lastStart = now
        notBefore = nil
    }

    /// Applies the outcome of the request started last.
    @discardableResult
    public mutating func finish(_ outcome: Outcome, at now: Date) -> Finished {
        switch outcome {
        case let .response(200, body, _):
            endBackoff()
            reading = ClaudeUsageEndpoint.limits(fromResponse: body, capturedAt: now)
            return Finished(summary: reading == nil ? "HTTP 200 with nothing readable" : "HTTP 200")
        case let .response(status, _, _) where status == 401 || status == 403:
            endBackoff()
            reading = nil
            return Finished(rereadToken: true, summary: "HTTP \(status): login refused")
        case let .response(status, _, retryAfter) where status == 429 || (500...599).contains(status):
            let wait = backOff(at: now, retryAfter: retryAfter)
            return Finished(summary: "HTTP \(status): keeping the last reading, next try in \(Int(wait / 60)) min")
        case let .response(status, _, _):
            endBackoff()
            reading = nil
            return Finished(summary: "HTTP \(status)")
        case .networkError:
            return Finished(summary: "network error: keeping the last reading")
        case .noCredentials:
            reading = nil
            let wait = backOff(at: now, retryAfter: nil)
            return Finished(summary: "no Claude Code login in the Keychain, next try in \(Int(wait / 60)) min")
        }
    }

    /// Holds off the next poll; returns the wait.
    private mutating func backOff(at now: Date, retryAfter: TimeInterval?) -> TimeInterval {
        backoffs += 1
        let doubling = min(Self.interval * pow(2, Double(min(backoffs, 10))), Self.maximumBackoff)
        let wait = min(max(doubling, retryAfter ?? 0), Self.maximumBackoff)
        notBefore = now + wait
        return wait
    }

    private mutating func endBackoff() {
        backoffs = 0
        notBefore = nil
    }

    /// A `Retry-After` header as a wait in seconds from `now`: either whole
    /// seconds (`120`) or an HTTP date (`Sun, 11 Oct 2026 07:28:00 GMT`; 0
    /// once passed). Nil when it's neither.
    public static func retryAfter(header: String?, at now: Date) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.allSatisfy(\.isASCIIDigit) {
            return TimeInterval(value)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isWholeNumber }
}

// MARK: - Recorded polls

extension ClaudeUsagePolling {
    /// One recorded request: when its answer arrived and what it was.
    ///
    /// ```json
    /// { "receivedAt": "…", "status": 200, "body": { …the response… } }
    /// { "receivedAt": "…", "status": 503, "body": "<html>…</html>", "retryAfter": 60 }
    /// { "receivedAt": "…", "failure": "network" }        // or "noCredentials"
    /// ```
    ///
    /// A `body` that's a JSON string is the body's text as is; anything else
    /// is the body's JSON.
    struct RecordedPoll: Decodable {
        var receivedAt: Date
        var outcome: Outcome

        private enum CodingKeys: String, CodingKey {
            case receivedAt, status, body, retryAfter, failure
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            receivedAt = try c.decode(Date.self, forKey: .receivedAt)
            if let status = try c.decodeIfPresent(Int.self, forKey: .status) {
                let body: Data = if let text = try? c.decode(String.self, forKey: .body) {
                    Data(text.utf8)
                } else if let json = try c.decodeIfPresent(JSONValue.self, forKey: .body) {
                    try JSONEncoder().encode(json)
                } else {
                    Data()
                }
                outcome = .response(status: status, body: body, retryAfter: try c.decodeIfPresent(Double.self, forKey: .retryAfter))
            } else {
                outcome = try c.decode(String.self, forKey: .failure) == "noCredentials" ? .noCredentials : .networkError
            }
        }
    }

    /// The endpoint's reading after these requests, in order, from launch.
    static func replay(_ polls: [RecordedPoll]) -> ClaudeLimits? {
        var polling = ClaudeUsagePolling()
        for poll in polls {
            polling.start(at: poll.receivedAt)
            polling.finish(poll.outcome, at: poll.receivedAt)
        }
        return polling.reading
    }
}

/// Any JSON value, to carry a recorded body through a fixture unchanged.
private enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(value): try c.encode(value)
        case let .number(value): try c.encode(value)
        case let .string(value): try c.encode(value)
        case let .array(value): try c.encode(value)
        case let .object(value): try c.encode(value)
        }
    }
}
