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
    public static let interval = PollSchedule.interval
    public static let minimumGap = PollSchedule.minimumGap

    public typealias Trigger = PollTrigger
    public typealias Outcome = PollOutcome

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
    private var schedule = PollSchedule()

    public init() {}

    /// Whether to ask the endpoint now.
    public func isDue(_ trigger: Trigger, at now: Date) -> Bool {
        schedule.isDue(trigger, at: now)
    }

    /// Notes that a request starts now.
    public mutating func start(at now: Date) {
        schedule.start(at: now)
    }

    /// Applies the outcome of the request started last.
    @discardableResult
    public mutating func finish(_ outcome: Outcome, at now: Date) -> Finished {
        switch outcome {
        case let .response(200, body, _):
            schedule.endBackoff()
            reading = ClaudeUsageEndpoint.limits(fromResponse: body, capturedAt: now)
            return Finished(summary: reading == nil ? "HTTP 200 with nothing readable" : "HTTP 200")
        case let .response(status, _, _) where status == 401 || status == 403:
            schedule.endBackoff()
            reading = nil
            return Finished(rereadToken: true, summary: "HTTP \(status): login refused")
        case let .response(status, _, retryAfter) where status == 429 || (500...599).contains(status):
            let wait = schedule.backOff(at: now, retryAfter: retryAfter)
            return Finished(summary: "HTTP \(status): keeping the last reading, next try in \(Int(wait / 60)) min")
        case let .response(status, _, _):
            schedule.endBackoff()
            reading = nil
            return Finished(summary: "HTTP \(status)")
        case .networkError:
            return Finished(summary: "network error: keeping the last reading")
        case .noCredentials:
            reading = nil
            let wait = schedule.backOff(at: now, retryAfter: nil)
            return Finished(summary: "no Claude Code login in the Keychain, next try in \(Int(wait / 60)) min")
        case let .blocked(reason):
            schedule.endBackoff()
            reading = nil
            return Finished(summary: "blocked: \(reason)")
        }
    }

    /// A `Retry-After` header as a wait in seconds from `now`.
    public static func retryAfter(header: String?, at now: Date) -> TimeInterval? {
        PollSchedule.retryAfter(header: header, at: now)
    }
}

// MARK: - Recorded polls

extension ClaudeUsagePolling {
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
