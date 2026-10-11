import Foundation
import Testing
import UsageCore

@Suite("Menu bar label")
struct MenuBarLabelTests {
    @Test("sample fixture shows Claude and Codex numbers")
    func sampleFixtureLabel() throws {
        let fixture = try loadFixture("sample")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        #expect(snapshot.menuBar.text == "✳ 61% · ⌘ 13%")
    }

    @Test("Claude shows the weekly window when it is higher than the 5-hour session")
    func weeklyHigher() {
        #expect(snapshot(claude: claude(fiveHour: 42, weekly: 61)).menuBar.claude.text == "61%")
    }

    @Test("Claude shows the 5-hour session when it is higher than the weekly window")
    func fiveHourHigher() {
        #expect(snapshot(claude: claude(fiveHour: 72, weekly: 61)).menuBar.claude.text == "72%")
    }

    @Test("Fable is left out of Claude's number, even when it is the highest")
    func fableExcluded() {
        let part = snapshot(claude: claude(fiveHour: 42, weekly: 61, fable: 97)).menuBar.claude
        #expect(part.text == "61%")
        #expect(part.level == .normal)
    }

    @Test("a service with no readings shows a dash")
    func noReadings() {
        #expect(snapshot(claude: claude()).menuBar.text == "✳ 61% · ⌘ —")
    }
}

@Suite("Levels")
struct LevelTests {
    @Test(
        "normal below 90%, warning from 90%, maxed at 100%",
        arguments: [
            (0.0, "0%", Level.normal),
            (89.0, "89%", .normal),
            (89.9, "89%", .normal),
            (90.0, "90%", .warning),
            (99.9, "99%", .warning),
        ]
    )
    func levels(used: Double, text: String, level: Level) {
        let part = snapshot(claude: claude(fiveHour: used, weekly: 0)).menuBar.claude
        #expect(part.text == text)
        #expect(part.level == level)
    }

    @Test("a maxed window is at the maxed level")
    func maxed() {
        #expect(snapshot(claude: claude(fiveHour: 100, weekly: 61)).menuBar.claude.level == .maxed)
    }

    @Test("Codex uses the same levels")
    func codexLevels() {
        #expect(snapshot(codex: codex(weekly: 13)).menuBar.codex.level == .normal)
        #expect(snapshot(codex: codex(weekly: 92)).menuBar.codex.level == .warning)
        #expect(snapshot(codex: codex(weekly: 100)).menuBar.codex.level == .maxed)
    }
}

@Suite("Countdown while maxed")
struct CountdownTests {
    @Test("a maxed 5-hour session shows the time until it resets")
    func fiveHourMaxed() {
        let part = snapshot(claude: claude(fiveHour: 100, weekly: 84, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00"))).menuBar.claude
        #expect(part.text == "1h 05m")
        #expect(part.level == .maxed)
    }

    @Test("a maxed weekly window shows days and hours until it resets")
    func weeklyMaxed() {
        // Sat 2:40 PM → Tue 7:00 AM is 2 days 16 hours 20 minutes.
        #expect(snapshot(claude: claude(fiveHour: 30, weekly: 100)).menuBar.claude.text == "2d 16h")
    }

    @Test("with both windows maxed, the countdown runs to the later reset")
    func bothMaxed() {
        #expect(snapshot(claude: claude(fiveHour: 100, weekly: 100)).menuBar.claude.text == "2d 16h")
    }

    @Test(
        "countdowns round up to the next minute",
        arguments: [
            ("2026-10-10T15:25:00-07:00", "45m"),
            ("2026-10-10T15:44:30-07:00", "1h 05m"),
            ("2026-10-10T14:40:20-07:00", "1m"),
        ]
    )
    func rounding(resetsAt: String, text: String) {
        #expect(snapshot(claude: claude(fiveHour: 100, fiveHourResetsAt: date(resetsAt))).menuBar.claude.text == text)
    }

    @Test("a maxed Fable window doesn't trigger the countdown")
    func fableMaxed() {
        #expect(snapshot(claude: claude(fiveHour: 42, weekly: 61, fable: 100)).menuBar.claude.text == "61%")
    }

    @Test("Codex shows a countdown too when its weekly window is maxed")
    func codexMaxed() {
        // Sat 2:40 PM → Thu 1:16 PM is 4 days 22 hours 36 minutes.
        #expect(snapshot(codex: codex(weekly: 100)).menuBar.codex.text == "4d 22h")
    }
}

@Suite("Windows past their reset")
struct PassedResetTests {
    @Test("a maxed 5-hour session that reset at 2 PM no longer counts")
    func maxedSessionReset() {
        let part = snapshot(claude: claude(fiveHour: 100, weekly: 61, fiveHourResetsAt: date("2026-10-10T14:00:00-07:00"))).menuBar.claude
        #expect(part.text == "61%")
        #expect(part.level == .normal)
    }

    @Test("a window reads 0% from the moment it resets")
    func resetExactlyNow() {
        #expect(snapshot(codex: codex(weekly: 95, resetsAt: now)).menuBar.codex.text == "0%")
    }

    @Test("a window that reset while the Mac slept reads 0% at wake")
    func resetWhileAsleep() {
        // Readings taken Saturday afternoon; the Mac wakes on Friday after the weekly reset.
        let wake = date("2026-10-16T09:00:00-07:00")
        let label = snapshot(claude: claude(fiveHour: 100, weekly: 100), codex: codex(weekly: 100), at: wake).menuBar
        #expect(label.text == "✳ 0% · ⌘ 0%")
        #expect(label.claude.level == .normal)
        #expect(label.codex.level == .normal)
    }
}
