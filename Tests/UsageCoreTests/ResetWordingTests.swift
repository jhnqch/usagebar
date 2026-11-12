import Foundation
import Testing
import UsageCore

/// The reset line under each meter: a countdown within a day, the weekday
/// and time beyond, and once passed, when it reset by the calendar day.
@Suite("Reset wording")
struct ResetWordingTests {
    func resetText(_ resetsAt: String) -> String? {
        snapshot(codex: codex(resetsAt: date(resetsAt))).codex.meters.first?.resetText
    }

    @Test("a reset earlier today reads its time alone")
    func earlierToday() {
        #expect(resetText("2026-10-10T11:00:00-07:00") == "Reset at 11:00 AM")
    }

    @Test("a reset that happened yesterday, under 24 hours ago, shows its weekday")
    func yesterday() {
        // Fri 9 Oct, 11:00 PM: 15h 40m before Sat 2:40 PM.
        #expect(resetText("2026-10-09T23:00:00-07:00") == "Reset Fri 11:00 PM")
    }

    @Test("a reset more than a day ago shows its weekday")
    func daysAgo() {
        #expect(resetText("2026-10-08T07:00:00-07:00") == "Reset Thu 7:00 AM")
    }

    @Test("a reset 23h 59m 30s away never reads 1d 0h: past the last minute of the day it shows the weekday")
    func almostADay() {
        let resetsAt = now + 24 * 3600 - 30
        let text = snapshot(codex: codex(resetsAt: resetsAt)).codex.meters.first?.resetText
        #expect(text == "Resets Sun 2:39 PM")
    }

    @Test("a reset 23h 58m 30s away counts down to the rounded-up minute")
    func justUnderADay() {
        let resetsAt = now + 24 * 3600 - 90
        let text = snapshot(codex: codex(resetsAt: resetsAt)).codex.meters.first?.resetText
        #expect(text == "Resets in 23h 59m (2:38 PM)")
    }
}
