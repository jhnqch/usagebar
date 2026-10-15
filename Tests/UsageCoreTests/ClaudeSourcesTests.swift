import Foundation
import Testing
import UsageCore

/// Claude's 5-hour and weekly windows come from both the status line and the
/// usage endpoint; Fable comes only from the endpoint.
///
/// Capture times can't pick between them: an idle Claude Code session
/// re-sends its old numbers with a fresh capture time. So per window:
/// - the same window (resets within 15 minutes of each other): the higher
///   percent wins, since use only goes up within a window;
/// - different windows: the one that resets later is the newer window;
/// - a window whose reset has passed reads 0%.
@Suite("Claude sources")
struct ClaudeSourcesTests {
    /// The response recorded from the usage endpoint at 11:24:52 PM:
    /// 5-hour 26% (resets 1:50 AM), weekly 12% and Fable 0% (reset Fri 12:00 AM).
    func recordedEndpoint() throws -> ClaudeLimits? {
        ClaudeUsageEndpoint.limits(
            fromResponse: try Data(contentsOf: fixtureURL("claude/usage-response.json")),
            capturedAt: date("2026-10-10T23:24:52-07:00")
        )
    }

    /// The recorded status line JSON (5-hour 19%, weekly 11%, in
    /// the same windows as the recorded response), as the command saves it
    /// when it runs at `time`.
    func recordedStatusLine(at time: Date) throws -> ClaudeLimits? {
        let afterReply = try fixtureLines("claude/status-line.jsonl")[1]
        return ClaudeStatusLine.run(input: afterReply, saved: nil, now: time).save.flatMap(ClaudeStatusLine.limits(fromSaved:))
    }

    func statusLine(fiveHour: Double, weekly: Double, capturedAt: Date,
                    fiveHourResetsAt: Date = date("2026-10-10T16:58:00-07:00"),
                    weeklyResetsAt: Date = date("2026-10-13T07:00:00-07:00")) -> ClaudeLimits {
        ClaudeLimits(
            capturedAt: capturedAt,
            fiveHour: LimitReading(usedPercent: fiveHour, resetsAt: fiveHourResetsAt),
            sevenDay: LimitReading(usedPercent: weekly, resetsAt: weeklyResetsAt)
        )
    }

    @Test("same window: a status line captured later with lower numbers loses to the endpoint")
    func staleStatusLineLoses() throws {
        // An idle session re-sends what it saw at 10:45 PM, stamped 11:30 PM.
        let section = snapshot(
            claude: try recordedEndpoint(),
            claudeStatusLine: try recordedStatusLine(at: date("2026-10-10T23:30:00-07:00")),
            at: date("2026-10-10T23:30:00-07:00")
        )
        #expect(section.claude.meters.map(\.percentText) == ["26%", "12%", "0%"])
        #expect(section.claude.meters.map(\.resetText) == ["Resets in 2h 20m (1:50 AM)", "Resets Fri 12:00 AM", "Resets Fri 12:00 AM"])
        #expect(section.menuBar.claude.text == "26%")
    }

    @Test("same window: a status line with higher numbers wins over a fresher endpoint reading")
    func higherStatusLineWins() throws {
        let section = snapshot(
            claude: try recordedEndpoint(),
            claudeStatusLine: statusLine(
                fiveHour: 31, weekly: 13, capturedAt: date("2026-10-10T23:20:00-07:00"),
                fiveHourResetsAt: date("2026-10-11T01:50:00-07:00"),
                weeklyResetsAt: date("2026-10-16T00:00:00-07:00")
            ),
            at: date("2026-10-10T23:30:00-07:00")
        )
        #expect(section.claude.meters.map(\.percentText) == ["31%", "13%", "0%"])
        #expect(section.menuBar.claude.text == "31%")
        #expect(section.claude.updatedText == "Updated 5 min ago")
    }

    @Test("resets up to 15 minutes apart are the same window: the higher percent wins")
    func resetsCloseTogether() {
        let section = snapshot(
            claude: claude(fiveHour: 42, weekly: 61),
            claudeStatusLine: statusLine(
                fiveHour: 40, weekly: 60, capturedAt: date("2026-10-10T14:39:00-07:00"),
                fiveHourResetsAt: date("2026-10-10T17:12:00-07:00"),
                weeklyResetsAt: date("2026-10-13T06:46:00-07:00")
            )
        )
        #expect(section.claude.meters.map(\.percentText) == ["42%", "61%", "34%"])
        // The winner's reset time comes with it.
        #expect(section.claude.meters[0].resetText == "Resets in 2h 18m (4:58 PM)")
    }

    @Test("different windows: the endpoint's new window wins over the status line's old one, even at a lower percent")
    func newerEndpointWindow() {
        // The status line last ran at 11:00 AM, near the end of the 5-hour
        // window that reset at 2:30 PM. The endpoint has the window after it.
        let section = snapshot(
            claude: claude(fiveHour: 3, weekly: 61, fiveHourResetsAt: date("2026-10-10T19:30:00-07:00")),
            claudeStatusLine: statusLine(
                fiveHour: 95, weekly: 58, capturedAt: date("2026-10-10T11:00:00-07:00"),
                fiveHourResetsAt: date("2026-10-10T14:30:00-07:00")
            )
        )
        #expect(section.claude.meters.map(\.percentText) == ["3%", "61%", "34%"])
        #expect(section.claude.meters[0].resetText == "Resets in 4h 50m (7:30 PM)")
        #expect(section.menuBar.claude.text == "61%")
    }

    @Test("different windows: the status line's new window wins over an older endpoint reading")
    func newerStatusLineWindow() {
        // The endpoint's last good reading is from the week before.
        let section = snapshot(
            claude: claude(fiveHour: 80, weekly: 97, fiveHourResetsAt: date("2026-10-06T09:00:00-07:00"), weeklyResetsAt: date("2026-10-06T07:00:00-07:00")),
            claudeStatusLine: statusLine(fiveHour: 12, weekly: 4, capturedAt: date("2026-10-10T14:39:00-07:00"))
        )
        // Its Fable window reset with last week's, so Fable reads 0%.
        #expect(section.claude.meters.map(\.percentText) == ["12%", "4%", "0%"])
        #expect(section.menuBar.claude.text == "12%")
    }

    @Test("a window whose reset has passed in both sources reads 0%")
    func passedReset() {
        let section = snapshot(
            claude: claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T14:30:00-07:00")),
            claudeStatusLine: statusLine(
                fiveHour: 97, weekly: 63, capturedAt: date("2026-10-10T14:00:00-07:00"),
                fiveHourResetsAt: date("2026-10-10T14:30:00-07:00")
            )
        )
        #expect(section.claude.meters[0].percentText == "0%")
        #expect(section.claude.meters[0].resetText == "Reset at 2:30 PM")
        #expect(section.menuBar.claude.text == "63%")
    }

    @Test("Fable comes only from the endpoint and stays out of the menu bar, even at 97%")
    func fableEndpointOnly() {
        let section = snapshot(
            claude: claude(fiveHour: 42, weekly: 61, fable: 97),
            claudeStatusLine: statusLine(fiveHour: 50, weekly: 63, capturedAt: date("2026-10-10T14:39:00-07:00"))
        )
        #expect(section.claude.meters.map(\.percentText) == ["50%", "63%", "97%"])
        #expect(section.claude.updatedText == "Updated 1 min ago")
        #expect(section.menuBar.claude.text == "63%")
    }

    @Test("with only Fable from the endpoint, 5-hour and weekly come from the status line, however old")
    func fableOnlyEndpoint() {
        let fableOnly = ClaudeLimits(
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

    @Test("with no endpoint reading, 5-hour and weekly come from the status line and Fable shows a dash")
    func noEndpoint() throws {
        let section = snapshot(
            claudeStatusLine: try recordedStatusLine(at: date("2026-10-10T22:45:53-07:00")),
            at: date("2026-10-10T23:30:00-07:00")
        )
        #expect(section.claude.meters.map(\.percentText) == ["19%", "11%", "—"])
        #expect(section.menuBar.claude.text == "19%")
    }

    @Test("with no status line yet, the endpoint's numbers show")
    func noStatusLine() throws {
        let section = snapshot(claude: try recordedEndpoint(), at: date("2026-10-10T23:30:00-07:00"))
        #expect(section.claude.meters.map(\.percentText) == ["26%", "12%", "0%"])
        #expect(section.claude.updatedText == "Updated 5 min ago")
        #expect(section.menuBar.claude.text == "26%")
    }

    @Test("with neither source, every Claude meter and the menu bar number show a dash")
    func noSources() {
        let section = snapshot()
        #expect(section.claude.meters.map(\.percentText) == ["—", "—", "—"])
        #expect(section.claude.updatedText == nil)
        #expect(section.menuBar.claude.text == "—")
    }
}
