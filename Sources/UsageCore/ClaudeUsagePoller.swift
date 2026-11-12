import Foundation

/// What Claude Code's saved login holds that UsageBar uses: the access
/// token, which goes only into the usage request's `Authorization` header,
/// and the plan for the badge.
public struct ClaudeLogin: Equatable, Sendable {
    public var token: String?
    public var plan: String?

    public init(token: String?, plan: String?) {
        self.token = token
        self.plan = plan
    }
}

/// Polls Claude's usage endpoint with `ClaudeUsagePolling`'s schedule and
/// answers. Reads the login when it has no token and keeps the token in
/// memory only. The token is read-only: it's never refreshed, logged or
/// stored here.
///
/// Claude Code rotates its token now and then. When a token kept from an
/// earlier poll is refused (401, 403), the poller reads the login once more
/// and, if the token there differs, retries at once with it, so the Fable
/// meter doesn't show "—" until the next due poll. A token read in the same
/// poll isn't read again, and there's at most one retry.
@MainActor
public final class ClaudeUsagePoller {
    /// The endpoint's latest reading; nil shows Fable as "—".
    public var reading: ClaudeLimits? { polling.reading }
    /// The plan from the latest login read; nil with no readable login.
    public private(set) var plan: String?

    private var polling = ClaudeUsagePolling()
    private var token: String?
    private var inFlight = false
    /// Bumped by `stop()`: an answer to a request from an earlier
    /// generation is dropped.
    private var generation = 0
    private let readLogin: () async -> ClaudeLogin?
    private let fetch: (String) async -> PollOutcome
    private let now: () -> Date
    private let log: (String) -> Void

    /// - Parameters:
    ///   - readLogin: Claude Code's saved login, or nil when there's none
    ///     or it can't be read.
    ///   - fetch: asks the endpoint with this token.
    ///   - log: one line per poll; never holds the token or the response.
    public init(
        readLogin: @escaping () async -> ClaudeLogin?,
        fetch: @escaping (String) async -> PollOutcome,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.readLogin = readLogin
        self.fetch = fetch
        self.now = now
        self.log = log
    }

    public func isDue(_ trigger: PollTrigger, at time: Date) -> Bool {
        polling.isDue(trigger, at: time)
    }

    /// Polls if one is due and none is under way. Returns whether it
    /// finished a poll whose readings are current (not dropped by `stop()`).
    @discardableResult
    public func poll(_ trigger: PollTrigger) async -> Bool {
        guard !inFlight, polling.isDue(trigger, at: now()) else { return false }
        inFlight = true
        let generation = generation
        defer {
            if generation == self.generation { inFlight = false }
        }
        polling.start(at: now())

        let cached = token != nil
        if !cached {
            let login = await readLogin()
            guard generation == self.generation else { return false }
            token = login?.token
            plan = login?.plan
        }
        let outcome: PollOutcome = if let token { await fetch(token) } else { .noCredentials }
        guard generation == self.generation else { return false }
        var finished = polling.finish(outcome, at: now())
        log(finished.summary)
        guard finished.rereadToken else { return true }

        let refused = token
        token = nil
        // A token read just now isn't read again: the next poll does that.
        guard cached else { return true }
        let login = await readLogin()
        guard generation == self.generation else { return false }
        plan = login?.plan
        guard let fresh = login?.token else {
            // No login left (or the Keychain prompt was denied): back off
            // as for no saved login, so the prompt doesn't come straight back.
            finished = polling.finish(.noCredentials, at: now())
            log(finished.summary)
            return true
        }
        guard fresh != refused else { return true }
        token = fresh
        polling.start(at: now())
        let retried = await fetch(fresh)
        guard generation == self.generation else { return false }
        finished = polling.finish(retried, at: now())
        log("retried with a newer token from the Keychain: \(finished.summary)")
        if finished.rereadToken {
            token = nil
        }
        return true
    }

    /// Forgets the token and drops any answer under way.
    public func stop() {
        token = nil
        generation += 1
        inFlight = false
    }
}
