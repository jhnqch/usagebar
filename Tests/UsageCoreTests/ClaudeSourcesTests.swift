import Foundation
import Testing
import UsageCore

/// Claude's 5-hour and weekly windows can come from the status line or the
/// usage endpoint (today the bundled sample stands in for it); Fable and the
/// plan come only from the endpoint.
@Suite("Claude sources")
struct ClaudeSourcesTests {
    func statusLine(fiveHour: Double, weekly: Double, capturedAt: Date) -> ClaudeLimits {
        ClaudeLimits(
            capturedAt: capturedAt,
            fiveHour: LimitReading(usedPercent: fiveHour, resetsAt: date("2026-10-10T16:58:00-07:00")),
            sevenDay: LimitReading(usedPercent: weekly, resetsAt: date("2026-10-13T07:00:00-07:00"))
        )
    }

    @Test("a status line reading newer than the endpoint's wins for 5-hour and weekly; Fable stays the endpoint's")
    func statusLineFresher() {
        let section = snapshot(
            claude: claude(fiveHour: 42, weekly: 61, fable: 97),
            claudeStatusLine: statusLine(fiveHour: 50, weekly: 63, capturedAt: date("2026-10-10T14:39:00-07:00"))
        )
        #expect(section.claude.meters.map(\.percentText) == ["50%", "63%", "97%"])
        #expect(section.claude.plan == "Max")
        #expect(section.claude.updatedText == "Updated 1 min ago")
        // Fable stays out of the menu bar even at 97%.
        #expect(section.menuBar.claude.text == "63%")
    }

    @Test("an endpoint reading newer than the status line's wins")
    func endpointFresher() {
        let section = snapshot(
            claude: claude(fiveHour: 42, weekly: 61, fable: 34),
            claudeStatusLine: statusLine(fiveHour: 50, weekly: 63, capturedAt: date("2026-10-10T14:20:00-07:00"))
        )
        #expect(section.claude.meters.map(\.percentText) == ["42%", "61%", "34%"])
        #expect(section.claude.updatedText == "Updated 3 min ago")
    }

    @Test("with only Fable from the endpoint, 5-hour and weekly come from the status line, however old")
    func fableOnlyEndpoint() {
        let fableOnly = ClaudeLimits(
            plan: "Max",
            capturedAt: nil,
            sevenDayFable: LimitReading(usedPercent: 34, resetsAt: date("2026-10-13T07:00:00-07:00"))
        )
        let section = snapshot(
            claude: fableOnly,
            claudeStatusLine: statusLine(fiveHour: 50, weekly: 63, capturedAt: date("2026-10-10T09:00:00-07:00"))
        )
        #expect(section.claude.meters.map(\.percentText) == ["50%", "63%", "34%"])
        #expect(section.claude.updatedText == "Updated at 9:00 AM")
        #expect(section.menuBar.claude.text == "63%")
    }

    @Test("with no status line yet, 5-hour and weekly show a dash and the menu bar number is a dash")
    func noStatusLine() {
        let fableOnly = ClaudeLimits(
            plan: "Max",
            capturedAt: nil,
            sevenDayFable: LimitReading(usedPercent: 34, resetsAt: date("2026-10-13T07:00:00-07:00"))
        )
        let section = snapshot(claude: fableOnly)
        #expect(section.claude.meters.map(\.percentText) == ["—", "—", "34%"])
        #expect(section.claude.updatedText == nil)
        #expect(section.menuBar.claude.text == "—")
    }
}
