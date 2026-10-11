import Foundation
import Testing
import UsageCore

@Suite("Readings files")
struct FixtureTests {
    @Test("missing, extra and renamed fields degrade one row to a dash")
    func tolerantDecoding() throws {
        let json = """
        {
          "now": "2026-10-10T14:40:00-07:00",
          "timeZone": "America/Los_Angeles",
          "somethingNew": true,
          "readings": {
            "claude": {
              "plan": "Max",
              "capturedAt": "2026-10-10T14:37:00-07:00",
              "fiveHour": { "usedPercent": 42, "resetsAt": "2026-10-10T16:58:00-07:00", "extra": 1 },
              "sevenDay": { "used_percent": 61, "resetsAt": "2026-10-13T07:00:00-07:00" },
              "sevenDayFable": { "usedPercent": "lots", "resetsAt": "2026-10-13T07:00:00-07:00" }
            },
            "codex": {
              "capturedAt": "2026-10-10T14:40:00-07:00",
              "windows": [
                { "usedPercent": 13, "windowMinutes": 10080, "resetsAt": "2026-10-15T13:16:00-07:00" },
                { "usedPercent": 50 }
              ]
            }
          }
        }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        #expect(snapshot.claude.meters.map(\.percentText) == ["42%", "—", "—"])
        #expect(snapshot.codex.meters.map(\.percentText) == ["13%"])
        #expect(snapshot.codex.plan == nil)
        #expect(snapshot.menuBar.text == "✳ 42% · ⌘ 13%")
    }

    @Test("a service whose block is malformed shows dashes; the other still shows")
    func malformedService() throws {
        let json = """
        {
          "now": "2026-10-10T14:40:00-07:00",
          "readings": {
            "claude": { "plan": "Max" },
            "codex": {
              "plan": "pro",
              "capturedAt": "2026-10-10T14:40:00-07:00",
              "windows": [{ "usedPercent": 13, "windowMinutes": 10080, "resetsAt": "2026-10-15T13:16:00-07:00" }]
            }
          }
        }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: losAngeles)
        #expect(snapshot.menuBar.text == "✳ — · ⌘ 13%")
    }

    @Test("a missing or mistyped capture time hides only the updated time")
    func missingCapturedAt() throws {
        let json = """
        {
          "now": "2026-10-10T14:40:00-07:00",
          "readings": {
            "claude": {
              "plan": "Max",
              "fiveHour": { "usedPercent": 42, "resetsAt": "2026-10-10T16:58:00-07:00" },
              "sevenDay": { "usedPercent": 61, "resetsAt": "2026-10-13T07:00:00-07:00" }
            },
            "codex": {
              "plan": "pro",
              "capturedAt": "a moment ago",
              "windows": [{ "usedPercent": 13, "windowMinutes": 10080, "resetsAt": "2026-10-15T13:16:00-07:00" }]
            }
          }
        }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: losAngeles)
        #expect(snapshot.menuBar.text == "✳ 61% · ⌘ 13%")
        #expect(snapshot.claude.meters.map(\.percentText) == ["42%", "61%", "—"])
        #expect(snapshot.claude.updatedText == nil)
        #expect(snapshot.codex.meters.map(\.percentText) == ["13%"])
        #expect(snapshot.codex.updatedText == nil)
    }

    @Test("a malformed Codex 5-hour window shows a dash, not 'no 5-hour limit'")
    func malformedCodexFiveHour() throws {
        let json = """
        {
          "now": "2026-10-10T14:40:00-07:00",
          "readings": {
            "codex": {
              "plan": "pro",
              "capturedAt": "2026-10-10T14:40:00-07:00",
              "windows": [
                { "usedPercent": 13, "windowMinutes": 10080, "resetsAt": "2026-10-15T13:16:00-07:00" },
                { "used_percent": 27, "windowMinutes": 300, "resetsAt": "2026-10-10T17:10:00-07:00" }
              ]
            }
          }
        }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        let codex = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: losAngeles).codex
        #expect(codex.meters.map(\.label) == ["5-hour session", "Weekly"])
        #expect(codex.meters.map(\.percentText) == ["—", "13%"])
        #expect(codex.note == nil)
    }

    @Test("the bundled sample, rebased to launch time, reads as it did when recorded")
    func rebasedSample() throws {
        let fixture = try loadFixture("sample")
        let launch = date("2026-11-20T09:00:00-08:00")
        let snapshot = UsageEngine.snapshot(from: fixture.readings(rebasedTo: launch), now: launch, timeZone: losAngeles)
        #expect(snapshot.menuBar.text == "✳ 61% · ⌘ 13%")
        #expect(snapshot.claude.updatedText == "Updated 3 min ago")
        #expect(snapshot.claude.meters[0].resetText == "Resets in 2h 18m (11:18 AM)")
        #expect(snapshot.codex.meters[0].resetText == "Resets Wed 7:36 AM")
    }

    @Test("a fixture can carry recorded app-server messages, decoded as the app decodes them")
    func recordedAppServerFixture() throws {
        let fixture = try loadFixture("codex-live")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        #expect(snapshot.menuBar.text == "✳ 61% · ⌘ 0%")
        #expect(snapshot.codex.plan == "Plus")
        #expect(snapshot.codex.updatedText == "Updated just now")
        #expect(snapshot.codex.meters.map(\.label) == ["Weekly"])
        #expect(snapshot.codex.meters.map(\.resetText) == ["Resets Sat 9:33 PM"])
    }

    @Test("a fixture can carry recorded session-log lines")
    func recordedSessionLogFixture() throws {
        let fixture = try loadFixture("codex-session-log")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        #expect(snapshot.menuBar.text == "✳ 61% · ⌘ 38%")
        #expect(snapshot.codex.plan == "Plus")
        #expect(snapshot.codex.meters.map(\.label) == ["5-hour session", "Weekly"])
        #expect(snapshot.codex.meters.map(\.percentText) == ["38%", "6%"])
    }

    @Test(
        "a fixture can carry recorded usage-endpoint polls, replayed as the app handles them",
        arguments: [
            ("claude-usage", "✳ 26% · ⌘ 13%", ["26%", "12%", "0%"], "Updated just now"),
            ("claude-usage-down", "✳ 19% · ⌘ 13%", ["19%", "11%", "—"], "Updated 39 min ago"),
            ("claude-usage-merge", "✳ 26% · ⌘ 13%", ["26%", "12%", "0%"], "Updated just now"),
        ]
    )
    func recordedUsagePolls(name: String, menuBar: String, percents: [String], updated: String) throws {
        let fixture = try loadFixture(name)
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        #expect(snapshot.menuBar.text == menuBar)
        #expect(snapshot.claude.meters.map(\.percentText) == percents)
        #expect(snapshot.claude.updatedText == updated)
        #expect(snapshot.claude.plan == "Max")
    }
}
