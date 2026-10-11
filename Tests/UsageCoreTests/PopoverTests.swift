import Foundation
import Testing
import UsageCore

@Suite("Popover sections")
struct PopoverTests {
    @Test("sample fixture: Claude has a meter per window with its reset time")
    func claudeSection() throws {
        let fixture = try loadFixture("sample")
        let claude = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone).claude
        #expect(claude.plan == "Max")
        #expect(claude.updatedText == "Updated 3 min ago")
        #expect(claude.meters.map(\.label) == ["5-hour session", "Weekly · all models", "Weekly · Fable"])
        #expect(claude.meters.map(\.percentText) == ["42%", "61%", "34%"])
        #expect(claude.meters.map(\.resetText) == [
            "Resets in 2h 18m (4:58 PM)",
            "Resets Tue 7:00 AM",
            "Resets Tue 7:00 AM",
        ])
        #expect(claude.meters.map(\.fraction) == [0.42, 0.61, 0.34])
        #expect(claude.note == nil)
    }

    @Test("sample fixture: Codex has a weekly meter and says there's no 5-hour limit")
    func codexSection() throws {
        let fixture = try loadFixture("sample")
        let codex = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone).codex
        #expect(codex.plan == "Pro")
        #expect(codex.updatedText == "Updated just now")
        #expect(codex.meters.map(\.label) == ["Weekly"])
        #expect(codex.meters.map(\.percentText) == ["13%"])
        #expect(codex.meters.map(\.resetText) == ["Resets Thu 1:16 PM"])
        #expect(codex.note == "No 5-hour limit on your plan")
    }

    @Test("near fixture: the 5-hour meter is at the warning level")
    func nearFixture() throws {
        let fixture = try loadFixture("near")
        let meter = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone).claude.meters[0]
        #expect(meter.percentText == "93%")
        #expect(meter.level == .warning)
        #expect(meter.resetText == "Resets in 1h 47m (4:27 PM)")
    }

    @Test("maxed fixture: the 5-hour meter says the limit is reached")
    func maxedFixture() throws {
        let fixture = try loadFixture("maxed")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        let meter = snapshot.claude.meters[0]
        #expect(meter.percentText == "100%")
        #expect(meter.fraction == 1)
        #expect(meter.level == .maxed)
        #expect(meter.resetText == "Resets in 1h 05m (3:45 PM)")
        #expect(meter.prediction?.text == "Limit reached")
        #expect(snapshot.menuBar.text == "✳ 1h 05m · ⌘ 13%")
    }

    @Test("a maxed weekly window names the reset day")
    func maxedWeekly() {
        let meter = snapshot(claude: claude(weekly: 100)).claude.meters[1]
        #expect(meter.resetText == "Resets Tue 7:00 AM")
        #expect(meter.prediction?.text == "Limit reached")
    }

    @Test("a meter past its reset reads 0% and says when it reset")
    func passedReset() {
        let meter = snapshot(claude: claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T14:00:00-07:00"))).claude.meters[0]
        #expect(meter.percentText == "0%")
        #expect(meter.fraction == 0)
        #expect(meter.level == .normal)
        #expect(meter.resetText == "Reset at 2:00 PM")
    }

    @Test("a window with no reading shows a dash and no reset time")
    func missingWindow() {
        let meter = snapshot(claude: claude(fable: nil)).claude.meters[2]
        #expect(meter.label == "Weekly · Fable")
        #expect(meter.percentText == "—")
        #expect(meter.fraction == 0)
        #expect(meter.resetText == nil)
    }

    @Test("with no Codex readings, the Codex section shows a dashed weekly meter")
    func noCodex() {
        let codex = snapshot(claude: claude()).codex
        #expect(codex.plan == nil)
        #expect(codex.updatedText == nil)
        #expect(codex.meters.map(\.label) == ["Weekly"])
        #expect(codex.meters.map(\.percentText) == ["—"])
        #expect(codex.note == nil)
    }

    @Test("a Codex 5-hour window gets its own meter, listed first")
    func codexFiveHour() {
        var limits = codex(weekly: 13)
        limits.windows.append(CodexWindow(usedPercent: 27, windowMinutes: 300, resetsAt: date("2026-10-10T17:10:00-07:00")))
        let section = snapshot(codex: limits).codex
        #expect(section.meters.map(\.label) == ["5-hour session", "Weekly"])
        #expect(section.meters.map(\.percentText) == ["27%", "13%"])
        #expect(section.note == nil)
    }

    @Test(
        "the updated time is relative within the hour, then a clock time",
        arguments: [
            ("2026-10-10T14:39:30-07:00", "Updated just now"),
            ("2026-10-10T14:37:00-07:00", "Updated 3 min ago"),
            ("2026-10-10T11:05:00-07:00", "Updated at 11:05 AM"),
            ("2026-10-08T09:30:00-07:00", "Updated Thu 9:30 AM"),
        ]
    )
    func updatedText(capturedAt: String, text: String) {
        var limits = claude()
        limits.capturedAt = date(capturedAt)
        #expect(snapshot(claude: limits).claude.updatedText == text)
    }
}
