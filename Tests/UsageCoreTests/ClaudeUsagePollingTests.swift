import Foundation
import Testing
import UsageCore

/// What each answer from the usage endpoint does to the Claude meters, and
/// when UsageBar asks it again.
@Suite("Claude usage polling")
struct ClaudeUsagePollingTests {
    /// Sat 10 Oct 2026, 11:24:52 PM in Los Angeles: when the response was recorded.
    let start = date("2026-10-10T23:24:52-07:00")

    func recordedResponse() throws -> Data {
        try Data(contentsOf: fixtureURL("claude/usage-response.json"))
    }

    /// The status line recorded for ticket #4: 5-hour 19% and weekly 11%,
    /// in the same windows as the recorded response.
    func recordedStatusLine() throws -> ClaudeLimits? {
        let afterReply = try fixtureLines("claude/status-line.jsonl")[1]
        return ClaudeStatusLine.run(input: afterReply, saved: nil, now: date("2026-10-10T22:45:53-07:00"))
            .save.flatMap(ClaudeStatusLine.limits(fromSaved:))
    }

    /// Polling after a good answer at `start`, then `outcome` a minute later.
    func polled(then outcome: ClaudeUsagePolling.Outcome) throws -> (ClaudeUsagePolling, ClaudeUsagePolling.Finished) {
        var polling = ClaudeUsagePolling()
        polling.start(at: start)
        polling.finish(.response(status: 200, body: try recordedResponse()), at: start)
        let later = start + 60
        polling.start(at: later)
        let finished = polling.finish(outcome, at: later)
        return (polling, finished)
    }

    func meters(_ polling: ClaudeUsagePolling) throws -> [String] {
        snapshot(claude: polling.reading, claudeStatusLine: try recordedStatusLine(), at: start + 90).claude.meters.map(\.percentText)
    }

    @Test("a good answer shows the endpoint's numbers")
    func goodAnswer() throws {
        var polling = ClaudeUsagePolling()
        polling.start(at: start)
        let finished = polling.finish(.response(status: 200, body: try recordedResponse()), at: start)
        #expect(try meters(polling) == ["26%", "12%", "0%"])
        #expect(!finished.rereadToken)
    }

    @Test("after a 401 or 403 only Fable shows a dash, and the next poll reads the login from the Keychain again", arguments: [401, 403])
    func loginRefused(status: Int) throws {
        let (polling, finished) = try polled(then: .response(status: status, body: Data()))
        #expect(try meters(polling) == ["19%", "11%", "—"])
        #expect(finished.rereadToken)
    }

    @Test("a network error keeps the last good reading")
    func networkError() throws {
        let (polling, finished) = try polled(then: .networkError)
        #expect(try meters(polling) == ["26%", "12%", "0%"])
        #expect(!finished.rereadToken)
    }

    @Test("a 429 or 5xx keeps the last good reading", arguments: [429, 500, 502, 503])
    func busy(status: Int) throws {
        let (polling, _) = try polled(then: .response(status: status, body: Data("<html>busy</html>".utf8)))
        #expect(try meters(polling) == ["26%", "12%", "0%"])
    }

    @Test("an answer with nothing readable, another HTTP error or no saved login shows a dash for Fable only")
    func unusable() throws {
        let outcomes: [ClaudeUsagePolling.Outcome] = [
            .response(status: 200, body: Data("<html>moved</html>".utf8)),
            .response(status: 200, body: Data("{}".utf8)),
            .response(status: 404, body: Data()),
            .response(status: 400, body: Data()),
            .noCredentials,
        ]
        for outcome in outcomes {
            let (polling, _) = try polled(then: outcome)
            #expect(try meters(polling) == ["19%", "11%", "—"], "\(outcome)")
        }
    }

    @Test("a missing Fable entry in an otherwise good answer shows a dash for Fable only")
    func missingFable() throws {
        let body = editing(try recordedResponse()) { json in
            json["limits"] = (json["limits"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String != "weekly_scoped" }
        }
        let (polling, _) = try polled(then: .response(status: 200, body: body))
        #expect(try meters(polling) == ["26%", "12%", "—"])
    }

    // MARK: - When to ask

    /// Polling that just finished one request at `start` with `outcome`.
    func finished(with outcome: ClaudeUsagePolling.Outcome) -> ClaudeUsagePolling {
        var polling = ClaudeUsagePolling()
        polling.start(at: start)
        polling.finish(outcome, at: start)
        return polling
    }

    /// The first time from `from` (checked every second) when a poll is due.
    func due(_ polling: ClaudeUsagePolling, _ trigger: ClaudeUsagePolling.Trigger, from: Date) -> TimeInterval? {
        (0...(2 * 3600)).lazy.map(TimeInterval.init).first { polling.isDue(trigger, at: from + $0) }
    }

    @Test("the first poll is due at once, on the timer or when the popover opens")
    func firstPoll() {
        let polling = ClaudeUsagePolling()
        #expect(polling.isDue(.timer, at: start))
        #expect(polling.isDue(.popover, at: start))
    }

    @Test("after a good answer the timer polls every 5 minutes and the popover at most once a minute")
    func schedule() throws {
        let polling = finished(with: .response(status: 200, body: try recordedResponse()))
        #expect(due(polling, .timer, from: start) == 300)
        #expect(due(polling, .popover, from: start) == 60)
    }

    @Test("a network error or a refused login keeps the normal schedule")
    func noBackoff() {
        for outcome in [ClaudeUsagePolling.Outcome.networkError, .response(status: 401, body: Data()), .response(status: 404, body: Data())] {
            let polling = finished(with: outcome)
            #expect(due(polling, .timer, from: start) == 300, "\(outcome)")
            #expect(due(polling, .popover, from: start) == 60, "\(outcome)")
        }
    }

    @Test("a 429 or 5xx backs off, doubling from 10 minutes to an hour, and the popover waits too; a good answer ends it")
    func backoff() throws {
        var polling = ClaudeUsagePolling()
        var time = start
        var waits: [TimeInterval?] = []
        for status in [429, 503, 429, 500, 429] {
            polling.start(at: time)
            polling.finish(.response(status: status, body: Data()), at: time)
            let wait = due(polling, .popover, from: time)
            #expect(due(polling, .timer, from: time) == wait)
            waits.append(wait)
            time += wait ?? 0
        }
        #expect(waits == [600, 1200, 2400, 3600, 3600])

        polling.start(at: time)
        polling.finish(.response(status: 200, body: try recordedResponse()), at: time)
        #expect(due(polling, .timer, from: time) == 300)
        #expect(due(polling, .popover, from: time) == 60)
    }

    @Test("a Retry-After longer than the backoff is honoured, up to an hour", arguments: [(1800.0, 1800.0), (60.0, 600.0), (86400.0, 3600.0)])
    func retryAfter(header: TimeInterval, wait: TimeInterval) {
        let polling = finished(with: .response(status: 429, body: Data(), retryAfter: header))
        #expect(due(polling, .popover, from: start) == wait)
    }

    @Test(
        "Retry-After is read as seconds or as an HTTP date",
        arguments: [
            ("1800", 1800.0),
            ("0", 0.0),
            // `start` is 06:24:52 GMT.
            ("Sun, 11 Oct 2026 06:54:52 GMT", 1800.0),
            ("Sun, 11 Oct 2026 06:00:00 GMT", 0.0),  // already passed
        ] as [(String, TimeInterval)]
    )
    func retryAfterHeader(header: String, seconds: TimeInterval) {
        #expect(ClaudeUsagePolling.retryAfter(header: header, at: start) == seconds)
    }

    @Test("a Retry-After that's neither seconds nor an HTTP date is ignored", arguments: ["", "soon", "-5", "nan", "inf", "1e400"])
    func unreadableRetryAfter(header: String) {
        #expect(ClaudeUsagePolling.retryAfter(header: header, at: start) == nil)
    }

    @Test("an HTTP-date Retry-After holds polling off until then")
    func retryAfterDate() {
        let retryAfter = ClaudeUsagePolling.retryAfter(header: "Sun, 11 Oct 2026 06:54:52 GMT", at: start)
        let polling = finished(with: .response(status: 429, body: Data(), retryAfter: retryAfter))
        #expect(due(polling, .popover, from: start) == 1800)
    }

    @Test("no saved login backs off too, so a denied Keychain prompt doesn't come back every 5 minutes")
    func noCredentialsBackoff() {
        let polling = finished(with: .noCredentials)
        #expect(due(polling, .timer, from: start) == 600)
    }

    @Test("a clock set back doesn't stop polling, even while backing off")
    func clockSetBack() throws {
        let polling = finished(with: .response(status: 200, body: try recordedResponse()))
        #expect(polling.isDue(.timer, at: start - 3600))
        // A 10-minute backoff, then the clock goes back an hour: the
        // backoff's deadline is an hour and ten minutes away on the new clock.
        let backingOff = finished(with: .response(status: 429, body: Data()))
        #expect(backingOff.isDue(.timer, at: start - 3600))
        #expect(backingOff.isDue(.popover, at: start - 3600))
        // That poll fails to connect: the old deadline doesn't come back.
        var afterRollback = backingOff
        afterRollback.start(at: start - 3600)
        afterRollback.finish(.networkError, at: start - 3600)
        #expect(due(afterRollback, .timer, from: start - 3600) == 300)
    }
}
