import Foundation

/// What asks for a poll of a rate-limited endpoint.
public enum PollTrigger: Sendable {
    /// The regular timer: every 5 minutes.
    case timer
    /// Opening the popover, Refresh, waking from sleep: at most once a minute.
    case popover
}

/// What came of one request to a polled endpoint.
public enum PollOutcome: Equatable, Sendable {
    /// An HTTP answer. `retryAfter` is the `Retry-After` header in seconds.
    case response(status: Int, body: Data, retryAfter: TimeInterval? = nil)
    /// No answer: offline, timed out, TLS failure.
    case networkError
    /// No credential to send: no saved login or key, or access denied.
    case noCredentials
    /// Never sent: the request would have taken a credential somewhere it
    /// mustn't go. The reason names the host, never the credential.
    case blocked(String)
}

/// When to poll an endpoint: every 5 minutes on the timer, at most once a
/// minute when the popover opens, and less often while backing off. A
/// back-off doubles from 10 minutes up to an hour, or longer if
/// `Retry-After` says so (also up to an hour). Claude's usage endpoint and
/// every key provider share it.
public struct PollSchedule: Equatable, Sendable {
    public static let interval: TimeInterval = 5 * 60
    public static let minimumGap: TimeInterval = 60
    public static let maximumBackoff: TimeInterval = 60 * 60

    private var lastStart: Date?
    /// While backing off, no poll before this.
    private var notBefore: Date?
    /// Back-offs in a row, for the doubling.
    private var backoffs = 0

    public init() {}

    /// Whether to poll now.
    public func isDue(_ trigger: PollTrigger, at now: Date) -> Bool {
        guard let lastStart else { return true }
        // A clock set back makes every deadline taken from the old clock
        // meaningless, the back-off's included: poll, and start over from now.
        guard now >= lastStart else { return true }
        if let notBefore, now < notBefore { return false }
        return now.timeIntervalSince(lastStart) >= (trigger == .timer ? Self.interval : Self.minimumGap)
    }

    /// Notes that a request starts now. Any back-off is over (or its
    /// deadline came from a clock since set back); the answer may start a
    /// new one.
    public mutating func start(at now: Date) {
        lastStart = now
        notBefore = nil
    }

    /// Holds off the next poll; returns the wait.
    @discardableResult
    public mutating func backOff(at now: Date, retryAfter: TimeInterval?) -> TimeInterval {
        backoffs += 1
        let doubling = min(Self.interval * pow(2, Double(min(backoffs, 10))), Self.maximumBackoff)
        let wait = min(max(doubling, retryAfter ?? 0), Self.maximumBackoff)
        notBefore = now + wait
        return wait
    }

    /// A good answer: the next poll follows the normal schedule.
    public mutating func endBackoff() {
        backoffs = 0
        notBefore = nil
    }

    /// Forgets everything: the next poll is due at once.
    public mutating func reset() {
        self = PollSchedule()
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

/// One recorded request: when its answer arrived and what it was.
///
/// ```json
/// { "receivedAt": "…", "status": 200, "body": { …the response… } }
/// { "receivedAt": "…", "status": 503, "body": "<html>…</html>", "retryAfter": 60 }
/// { "receivedAt": "…", "failure": "network" }        // or "noCredentials"
/// ```
///
/// A `body` that's a JSON string is the body's text as is; anything else
/// is the body's JSON. Recordings hold answers only, never what was sent.
struct RecordedPoll: Decodable {
    var receivedAt: Date
    var outcome: PollOutcome

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
