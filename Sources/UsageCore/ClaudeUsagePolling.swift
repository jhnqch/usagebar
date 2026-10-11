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
        if let notBefore, now < notBefore { return false }
        guard let lastStart, now >= lastStart else { return true }  // also when the clock was set back
        return now.timeIntervalSince(lastStart) >= (trigger == .timer ? Self.interval : Self.minimumGap)
    }

    /// Notes that a request starts now.
    public mutating func start(at now: Date) {
        lastStart = now
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
}
