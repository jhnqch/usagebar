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

    @Test("a fixture can carry recorded transcript lines, read and priced as the app reads them")
    func recordedTranscriptFixture() throws {
        // Five days of replies across Opus 5.5, Fable 5.1, Sonnet 5.5, Haiku
        // 5.5 (prompts over 100K, so its higher rates) and an unreleased
        // "claude-opus-6"; one reply logged twice while streaming; one
        // <synthetic> line. Dollars worked out separately from the pricing page.
        let fixture = try loadFixture("claude-cost")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        let chart = try #require(snapshot.claude.chart)
        #expect(chart.title == "This week")
        #expect(chart.rangeText == "Tue 7 AM to Tue 7 AM · 2d 16h left")
        #expect(chart.days.map { ($0.dollars * 100).rounded() / 100 } == [43.77, 119.46, 68.02, 103.71, 80.76, 0, 0, 0])
        #expect(chart.legend.map(\.name) == ["Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 5.5", "claude-opus-6"])
        #expect(chart.legend.map(\.valueText) == [
            "$313 · 1B tokens", "$66 · 63M tokens", "$7.61 · 41M tokens", "$29 · 13M tokens", "no price · 38M tokens",
        ])
        #expect(chart.totalText == "$416 · 1.2B tokens")
        #expect(snapshot.claude.meters[0].usageText == "$42 · 100M tokens this session")
    }

    @Test("a fixture can carry recorded Codex rollout files, read file by file and priced as the app reads them")
    func recordedRolloutFixture() throws {
        // Three days into Codex's Thu 1:16 PM window: GPT-6-Astra sessions
        // (one response before the window opens), a switch to GPT-6.1-Sol,
        // a `codex review` pair whose parent logs no usage, a GPT-6-Luna
        // subagent and "codex-auto-review", which has no public price.
        // Dollars worked out separately from OpenAI's pricing page.
        let fixture = try loadFixture("codex-cost")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        let chart = try #require(snapshot.codex.chart)
        #expect(chart.rangeText == "Thu 1:16 PM to Thu 1:16 PM · 4d 22h left")
        #expect(chart.days.map(\.label) == ["Thu", "Fri", "Today", "Sun", "Mon", "Tue", "Wed", "Thu"])
        #expect(chart.days.map { ($0.dollars * 1000).rounded() / 1000 } == [3.774, 8.098, 3.661, 0, 0, 0, 0, 0])
        #expect(chart.legend.map(\.name) == ["GPT-6-Astra", "GPT-6.1-Sol", "GPT-6-Luna", "codex-auto-review"])
        #expect(chart.legend.map(\.valueText) == [
            "$15 · 5.5M tokens", "$0.79 · 1.5M tokens", "$0.03 · 732K tokens", "no price · 182K tokens",
        ])
        #expect(chart.totalText == "$16 · 7.9M tokens")
        // Rebased for the app, the usage moves with the window.
        let later = fixture.now + 3 * 24 * 60 * 60
        let rebased = UsageEngine.snapshot(from: fixture.readings(rebasedTo: later), now: later, timeZone: fixture.timeZone)
        #expect(rebased.codex.chart?.legend == chart.legend)
    }
}
