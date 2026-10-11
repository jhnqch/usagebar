import Foundation
import Testing
import UsageCore

/// The engine run as the app runs it: each evaluation gets the alert memory
/// the one before returned.
struct AlertRun {
    var memory = AlertMemory()

    /// The alerts one evaluation fires, keeping the memory it returns.
    mutating func callAsFunction(
        claude: ClaudeLimits? = nil,
        claudeStatusLine: ClaudeLimits? = nil,
        codex: CodexLimits? = nil,
        at time: Date = now
    ) -> [LimitAlert] {
        let snapshot = UsageEngine.snapshot(
            from: Readings(claude: claude, claudeStatusLine: claudeStatusLine, codex: codex),
            now: time,
            timeZone: losAngeles,
            alertMemory: memory
        )
        memory = snapshot.alertMemory
        return snapshot.alerts
    }

    /// Quits and relaunches: the memory goes through the saved file.
    mutating func restart() {
        memory = AlertMemory.decode(memory.encoded())
    }
}

@Suite("90% alerts")
struct NearLimitAlertTests {
    @Test("a window crossing 90% fires one alert naming the service and the window, with its reset and pace")
    func crossing() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 89)) == [])
        // 90% after 162 of 300 minutes: the other 10% takes 18 minutes, 2:58 PM.
        let alerts = run(claude: claude(fiveHour: 90))
        #expect(alerts.map(\.title) == ["Claude 5-hour session at 90%"])
        #expect(alerts.map(\.body) == ["Resets 4:58 PM · ahead of pace: limit around 3:00 PM"])
    }

    @Test("hovering around 90% fires once: dropping back and crossing again in the same cycle stays quiet")
    func hovering() {
        var run = AlertRun()
        let fired = [89, 90, 89.5, 91, 88, 93, 90.2].map { run(claude: claude(fiveHour: $0)).map(\.title) }
        #expect(fired == [[], ["Claude 5-hour session at 90%"], [], [], [], [], []])
    }

    @Test("a reset time that moves within 15 minutes is the same cycle: the sources round it differently")
    func sameCycleJitter() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 91)).count == 1)
        // The status line says 4:58 PM, the endpoint 4:57:59.82; 12 minutes off is still within 15.
        #expect(run(claudeStatusLine: claude(fiveHour: 92, fiveHourResetsAt: date("2026-10-10T16:57:59.820-07:00"))) == [])
        #expect(run(claude: claude(fiveHour: 93, fiveHourResetsAt: date("2026-10-10T17:10:00-07:00"))) == [])
    }

    @Test("the next cycle alerts again")
    func nextCycle() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 95)).count == 1)
        // The next 5-hour window, from 5:30 PM to 10:30 PM, at 9:45 PM.
        let alerts = run(claude: claude(fiveHour: 92, fiveHourResetsAt: date("2026-10-10T22:30:00-07:00")),
                         at: date("2026-10-10T21:45:00-07:00"))
        // 92% after 255 minutes: the other 8% takes 22 minutes, 10:07 PM.
        #expect(alerts.map(\.title) == ["Claude 5-hour session at 92%"])
        #expect(alerts.map(\.body) == ["Resets 10:30 PM · ahead of pace: limit around 10:05 PM"])
    }

    @Test(
        "every window alerts, named by service and window",
        arguments: [
            (claude(fiveHour: 0, weekly: 90, fable: 0), nil, "Claude weekly limit at 90%"),
            (claude(fiveHour: 0, weekly: 0, fable: 97.6), nil, "Claude weekly Fable limit at 97%"),
            (nil, codex(weekly: 91), "Codex weekly limit at 91%"),
            (nil, CodexLimits(capturedAt: now, windows: [
                CodexWindow(usedPercent: 94, windowMinutes: 300, resetsAt: date("2026-10-10T16:10:00-07:00")),
                CodexWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: date("2026-10-15T13:16:00-07:00")),
            ]), "Codex 5-hour session at 94%"),
            (nil, CodexLimits(capturedAt: now, windows: [
                CodexWindow(usedPercent: 90, windowMinutes: 1440, resetsAt: date("2026-10-11T08:40:00-07:00")),
            ]), "Codex 1-day limit at 90%"),
        ] as [(ClaudeLimits?, CodexLimits?, String)]
    )
    func everyWindow(claude: ClaudeLimits?, codex: CodexLimits?, title: String) {
        var run = AlertRun()
        #expect(run(claude: claude, codex: codex).map(\.title) == [title])
        #expect(run(claude: claude, codex: codex) == [])
    }

    @Test("a weekly alert gives the reset's day: the notification may be read on another")
    func weeklyBody() {
        var run = AlertRun()
        // 90% after 6220 of 10080 minutes: the other 10% takes 691 minutes, Sun 2:11 AM.
        #expect(run(claude: claude(weekly: 90)).map(\.body) == ["Resets Tue 7:00 AM · ahead of pace: limit around Sun 2 AM"])
    }

    @Test("windows crossing together alert together, in the popover's order")
    func together() {
        var run = AlertRun()
        let alerts = run(claude: claude(fiveHour: 96, weekly: 92, fable: 34), codex: codex(weekly: 90))
        #expect(alerts.map(\.title) == ["Claude 5-hour session at 96%", "Claude weekly limit at 92%", "Codex weekly limit at 90%"])
    }

    @Test("launching with a window already at 90% or more alerts once")
    func launchAbove() {
        var run = AlertRun()
        // Nothing read yet at launch, then the first readings arrive.
        #expect(run() == [])
        #expect(run(claude: claude(fiveHour: 93)).map(\.title) == ["Claude 5-hour session at 93%"])
        #expect(run(claude: claude(fiveHour: 93), at: now + 30) == [])
    }

    @Test("a reading whose reset has passed is old news: it reads 0% and doesn't alert")
    func passed() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 97, fiveHourResetsAt: date("2026-10-10T14:00:00-07:00"))) == [])
    }

    @Test("a window first seen maxed says the limit is reached, and when it resets")
    func firstSeenMaxed() {
        var run = AlertRun()
        let alerts = run(claude: claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00")))
        #expect(alerts.map(\.title) == ["Claude 5-hour limit reached"])
        #expect(alerts.map(\.body) == ["Resets 3:45 PM"])
    }

    @Test("a window that crossed 90% stays quiet on reaching 100%: one alert per cycle")
    func maxedAfterWarning() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 91)).count == 1)
        #expect(run(claude: claude(fiveHour: 100), at: now + 60) == [])
    }
}

@Suite("Reset alerts")
struct ResetAlertTests {
    /// The 5-hour window at 100%, resetting at 3:45 PM.
    static let maxed = claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00"))

    @Test("a window that reached 100% alerts once when its reset time passes")
    func resetAfterMax() {
        var run = AlertRun()
        #expect(run(claude: Self.maxed).map(\.title) == ["Claude 5-hour limit reached"])
        #expect(run(claude: Self.maxed, at: date("2026-10-10T15:44:59-07:00")) == [])
        // The source still holds the old reading, which now reads 0%.
        let alerts = run(claude: Self.maxed, at: date("2026-10-10T15:45:20-07:00"))
        #expect(alerts.map(\.title) == ["Claude 5-hour limit reset"])
        #expect(alerts.map(\.body) == ["You're good to go."])
        #expect(run(claude: Self.maxed, at: date("2026-10-10T15:45:50-07:00")) == [])
        #expect(run(claude: claude(fiveHour: 3, fiveHourResetsAt: date("2026-10-10T20:50:00-07:00")),
                    at: date("2026-10-10T15:51:00-07:00")) == [])
    }

    @Test("a window that reached 100% alerts when it's seen in a new cycle before the old reset time")
    func earlyReset() {
        var run = AlertRun()
        #expect(run(claude: Self.maxed).count == 1)
        // At 3 PM the limit is back, in a window that ends at 8 PM.
        let alerts = run(claude: claude(fiveHour: 1, fiveHourResetsAt: date("2026-10-10T20:00:00-07:00")),
                         at: date("2026-10-10T15:00:00-07:00"))
        #expect(alerts.map(\.title) == ["Claude 5-hour limit reset"])
        #expect(alerts.map(\.body) == ["You're good to go."])
        #expect(run(claude: Self.maxed, at: date("2026-10-10T15:50:00-07:00")) == [])
    }

    @Test("a window that only reached 90% doesn't announce its reset")
    func nearOnly() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 99.9, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00"))).count == 1)
        #expect(run(at: date("2026-10-10T15:46:00-07:00")) == [])
    }

    @Test("a window maxed after its 90% alert announces its reset")
    func maxedAfterNear() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 92, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00"))).count == 1)
        #expect(run(claude: Self.maxed, at: now + 600) == [])
        #expect(run(at: date("2026-10-10T15:46:00-07:00")).map(\.title) == ["Claude 5-hour limit reset"])
    }

    @Test("asleep through the reset: the first evaluation after waking announces it once, saying when it was")
    func sleptThrough() {
        var run = AlertRun()
        #expect(run(claude: Self.maxed).count == 1)
        // Woken at 9:10 PM; nothing read yet.
        let evening = run(at: date("2026-10-10T21:10:00-07:00"))
        #expect(evening.map(\.title) == ["Claude 5-hour limit reset"])
        #expect(evening.map(\.body) == ["Reset at 3:45 PM. You're good to go."])
        #expect(run(claude: Self.maxed, at: date("2026-10-10T21:10:30-07:00")) == [])

        // Asleep until the next morning, the reset is a day back.
        var overnight = AlertRun()
        #expect(overnight(claude: Self.maxed).count == 1)
        #expect(overnight(claude: Self.maxed, at: date("2026-10-11T09:10:00-07:00")).map(\.body)
            == ["Reset Sat 3:45 PM. You're good to go."])
    }

    @Test("a weekly limit maxed in Claude's weekly and Codex's windows announces each reset")
    func weeklyResets() {
        var run = AlertRun()
        let weeklyReset = date("2026-10-13T07:00:00-07:00")
        #expect(run(claude: claude(fiveHour: 10, weekly: 100, fable: 100), codex: codex(weekly: 100)).count == 3)
        let tuesday = run(at: weeklyReset + 60)
        #expect(tuesday.map(\.title) == ["Claude weekly limit reset", "Claude weekly Fable limit reset"])
        let thursday = run(at: date("2026-10-15T13:16:30-07:00"))
        #expect(thursday.map(\.title) == ["Codex weekly limit reset"])
    }

    @Test("the reset waits for the latest reset time the cycle was given, while the window still reads maxed")
    func latestResetInCycle() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 100)).count == 1)
        // A later reading of the same cycle puts the reset a minute later, so the meter still reads 100%.
        let later = claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T16:59:00-07:00"))
        #expect(run(claude: later, at: date("2026-10-10T16:58:30-07:00")) == [])
        #expect(run(claude: later, at: date("2026-10-10T16:59:00-07:00")).map(\.title) == ["Claude 5-hour limit reset"])
    }

    @Test("a maxed window that's no longer reported still announces its reset")
    func windowGone() {
        var run = AlertRun()
        let fiveHour = CodexLimits(capturedAt: now, windows: [
            CodexWindow(usedPercent: 100, windowMinutes: 300, resetsAt: date("2026-10-10T16:10:00-07:00")),
            CodexWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: date("2026-10-15T13:16:00-07:00")),
        ])
        #expect(run(codex: fiveHour).map(\.title) == ["Codex 5-hour limit reached"])
        // Codex stops reporting, then reports the weekly window alone.
        #expect(run(at: date("2026-10-10T16:00:00-07:00")) == [])
        #expect(run(codex: codex(weekly: 41), at: date("2026-10-10T16:11:00-07:00")).map(\.title) == ["Codex 5-hour limit reset"])
    }
}

@Suite("Alert memory")
struct AlertMemoryTests {
    @Test("a restart reloads the saved memory, so nothing is repeated")
    func restart() {
        var run = AlertRun()
        let maxed = claude(fiveHour: 100, weekly: 93, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00"))
        #expect(run(claude: maxed).map(\.title) == ["Claude 5-hour limit reached", "Claude weekly limit at 93%"])
        run.restart()
        #expect(run(claude: maxed, at: now + 60) == [])
        #expect(run(claude: maxed, at: date("2026-10-10T15:46:00-07:00")).map(\.title) == ["Claude 5-hour limit reset"])
        run.restart()
        #expect(run(claude: maxed, at: date("2026-10-10T15:47:00-07:00")) == [])
    }

    @Test("a restart while asleep through a reset announces it once on the first evaluation")
    func restartAfterReset() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00"))).count == 1)
        run.restart()
        #expect(run(at: date("2026-10-10T18:00:00-07:00")).map(\.body) == ["Reset at 3:45 PM. You're good to go."])
        run.restart()
        #expect(run(at: date("2026-10-10T18:00:30-07:00")) == [])
    }

    @Test("an unreadable file starts from an empty memory; an unreadable entry is dropped, the rest kept")
    func tolerant() throws {
        #expect(AlertMemory.decode(Data("not json".utf8)) == AlertMemory())
        #expect(AlertMemory.decode(Data()) == AlertMemory())
        // Resets Sat 4:58 PM and Thu 1:16 PM, Los Angeles time.
        let file = """
        {"cycles": [
          {"window": "claude.fiveHour", "name": "Claude 5-hour limit", "resetsAt": 1791676680,
           "warned": true, "maxed": false, "resetAnnounced": false, "extra": 1},
          {"window": "claude.sevenDay", "resetsAt": "yesterday"},
          {"window": "codex.10080m", "name": "Codex weekly limit", "resetsAt": 1792095360, "warned": true}
        ]}
        """
        let memory = AlertMemory.decode(Data(file.utf8))
        #expect(memory.cycles.map(\.window) == ["claude.fiveHour", "codex.10080m"])
        #expect(memory.cycles.map(\.warned) == [true, true])
        #expect(memory.cycles.map(\.maxed) == [false, false])
        var run = AlertRun(memory: memory)
        #expect(run(claude: claude(fiveHour: 95), codex: codex(weekly: 96)) == [])
    }

    @Test("cycles a week past their reset are forgotten, and a reset that old isn't announced")
    func pruned() {
        var run = AlertRun()
        #expect(run(claude: claude(fiveHour: 100, weekly: 92)).count == 2)
        #expect(run.memory.cycles.map(\.window) == ["claude.fiveHour", "claude.sevenDay"])
        // Six days after the 5-hour reset the cycle is still kept, and its reset announced.
        #expect(run(at: date("2026-10-16T16:58:00-07:00")).map(\.title) == ["Claude 5-hour limit reset"])
        #expect(run.memory.cycles.map(\.window) == ["claude.fiveHour", "claude.sevenDay"])
        // A week after each reset, it's gone.
        _ = run(at: date("2026-10-17T16:58:01-07:00"))
        #expect(run.memory.cycles.map(\.window) == ["claude.sevenDay"])
        _ = run(at: date("2026-10-20T07:00:01-07:00"))
        #expect(run.memory.cycles.isEmpty)

        var late = AlertRun()
        #expect(late(claude: claude(fiveHour: 100)).count == 1)
        #expect(late(at: date("2026-10-17T17:00:00-07:00")) == [])
        #expect(late.memory.cycles.isEmpty)
    }

    @Test("absurd numbers don't crash the alerts or the saved memory")
    func absurd() {
        var run = AlertRun()
        let absurd = ClaudeLimits(capturedAt: now, fiveHour: LimitReading(usedPercent: 1e20, resetsAt: Date(timeIntervalSince1970: 1e300)))
        #expect(run(claudeStatusLine: absurd).map(\.title) == ["Claude 5-hour limit reached"])
        run.restart()
        #expect(run(claudeStatusLine: absurd, at: now + 30) == [])
    }
}
