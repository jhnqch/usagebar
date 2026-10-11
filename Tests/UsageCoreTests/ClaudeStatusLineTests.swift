import Foundation
import Testing
import UsageCore

/// Status line JSON recorded from Claude Code 2.1.296 on this Mac (scrubbed):
/// line 0 when the session started, line 1 after its first reply.
@Suite("Claude status line")
struct ClaudeStatusLineTests {
    /// When the recorded reply's status line ran: Sat 10 Oct 2026, 10:45:53 PM in Los Angeles.
    let repliedAt = date("2026-10-10T22:45:53-07:00")

    func recorded() throws -> (sessionStart: Data, afterReply: Data) {
        let lines = try fixtureLines("claude/status-line.jsonl")
        return (lines[0], lines[1])
    }

    @Test("the recorded status line JSON shows Claude's 5-hour and weekly windows")
    func recordedReply() throws {
        let run = ClaudeStatusLine.run(input: try recorded().afterReply, saved: nil, now: repliedAt)
        let limits = try #require(run.save.flatMap(ClaudeStatusLine.limits(fromSaved:)))
        let section = snapshot(claudeStatusLine: limits, at: date("2026-10-10T22:46:00-07:00"))
        #expect(section.menuBar.claude.text == "19%")
        #expect(section.claude.updatedText == "Updated just now")
        #expect(section.claude.meters.map(\.percentText) == ["19%", "11%", "—"])
        #expect(section.claude.meters.map(\.resetText) == ["Resets in 3h 04m (1:50 AM)", "Resets Fri 12:00 AM", nil])
    }

    @Test("the command prints the model and both windows")
    func recordedLine() throws {
        #expect(ClaudeStatusLine.run(input: try recorded().afterReply, saved: nil, now: repliedAt).line == "Opus 5.5 · 5h 19% · wk 11%")
    }

    @Test("before the session's first reply there are no rate limits: just the model, and nothing saved")
    func sessionStart() throws {
        let run = ClaudeStatusLine.run(input: try recorded().sessionStart, saved: nil, now: repliedAt)
        #expect(run.line == "Opus 5.5")
        #expect(run.save == nil)
    }

    @Test("a window Claude Code drops after its reset stays saved and reads 0% until a new one arrives")
    func droppedWindow() throws {
        let saved = ClaudeStatusLine.run(input: try recorded().afterReply, saved: nil, now: repliedAt).save
        // The 5-hour window reset at 1:50 AM, so Claude Code dropped it.
        let dropped = editing(try recorded().afterReply) { $0["rate_limits", "five_hour"] = nil }
        let run = ClaudeStatusLine.run(input: dropped, saved: saved, now: date("2026-10-11T02:10:00-07:00"))
        #expect(run.line == "Opus 5.5 · 5h 0% · wk 11%")
        let limits = try #require((run.save ?? saved).flatMap(ClaudeStatusLine.limits(fromSaved:)))
        let section = snapshot(claudeStatusLine: limits, at: date("2026-10-11T02:11:00-07:00"))
        #expect(section.claude.meters.map(\.percentText) == ["0%", "11%", "—"])
        #expect(section.claude.meters.map(\.resetText) == ["Reset at 1:50 AM", "Resets Fri 12:00 AM", nil])
        #expect(section.menuBar.claude.text == "11%")
        #expect(section.claude.updatedText == "Updated 1 min ago")
    }

    @Test("an idle session's older numbers don't overwrite newer ones another session saved")
    func staleSession() throws {
        let afterReply = try recorded().afterReply
        // A second session replied at 11:30 PM, in the same windows.
        let newer = editing(afterReply) {
            $0["rate_limits", "five_hour", "used_percentage"] = 27
            $0["rate_limits", "seven_day", "used_percentage"] = 13
        }
        let saved = ClaudeStatusLine.run(input: newer, saved: nil, now: date("2026-10-10T23:30:00-07:00")).save
        // The first session re-runs its status line (a mode change, say) with what it saw at 10:45 PM.
        let run = ClaudeStatusLine.run(input: afterReply, saved: saved, now: date("2026-10-10T23:40:00-07:00"))
        #expect(run.save == nil)
        #expect(run.line == "Opus 5.5 · 5h 27% · wk 13%")
    }

    @Test("a new window after a reset replaces the saved one, even at a lower percent")
    func newWindow() throws {
        let afterReply = try recorded().afterReply
        let saved = ClaudeStatusLine.run(input: afterReply, saved: nil, now: repliedAt).save
        let nextWindow = editing(afterReply) {
            $0["rate_limits", "five_hour", "used_percentage"] = 3
            $0["rate_limits", "five_hour", "resets_at"] = 1_791_726_600  // Sun 6:50 AM
            $0["rate_limits", "seven_day", "used_percentage"] = 12
        }
        let run = ClaudeStatusLine.run(input: nextWindow, saved: saved, now: date("2026-10-11T02:10:00-07:00"))
        #expect(run.line == "Opus 5.5 · 5h 3% · wk 12%")
        let limits = try #require(run.save.flatMap(ClaudeStatusLine.limits(fromSaved:)))
        let section = snapshot(claudeStatusLine: limits, at: date("2026-10-11T02:10:00-07:00"))
        #expect(section.claude.meters.map(\.percentText) == ["3%", "12%", "—"])
        #expect(section.claude.meters[0].resetText == "Resets in 4h 40m (6:50 AM)")
    }

    @Test("input that isn't status line JSON prints a fallback and saves nothing", arguments: ["", "not json", "[1,2]", #"{"model":7}"#])
    func malformedInput(input: String) {
        let run = ClaudeStatusLine.run(input: Data(input.utf8), saved: nil, now: repliedAt)
        #expect(run.line == "Claude")
        #expect(run.save == nil)
    }

    @Test("a window with a renamed field degrades to a dash; the other window and extra fields don't matter")
    func renamedField() throws {
        let input = editing(try recorded().afterReply) {
            $0["rate_limits", "five_hour", "used_percentage"] = nil
            $0["rate_limits", "five_hour", "used_pct"] = 19
            $0["rate_limits", "seven_day", "something_new"] = [1, 2]
            $0["rate_limits", "spend_limit"] = ["used_percentage": 62.8, "resets_at": 1_792_134_000]
        }
        let run = ClaudeStatusLine.run(input: input, saved: nil, now: repliedAt)
        #expect(run.line == "Opus 5.5 · wk 11%")
        let limits = try #require(run.save.flatMap(ClaudeStatusLine.limits(fromSaved:)))
        let section = snapshot(claudeStatusLine: limits, at: repliedAt)
        #expect(section.claude.meters.map(\.percentText) == ["—", "11%", "—"])
        #expect(section.menuBar.claude.text == "11%")
    }

    @Test("rate limits that are null or unreadable print just the model")
    func unreadableRateLimits() throws {
        for rateLimits in [NSNull(), "soon", ["five_hour": "full"]] as [Any] {
            let input = editing(try recorded().afterReply) { $0["rate_limits"] = rateLimits }
            let run = ClaudeStatusLine.run(input: input, saved: nil, now: repliedAt)
            #expect(run.line == "Opus 5.5")
            #expect(run.save == nil)
        }
    }

    @Test("a model with no display name goes by its id, then by \"Claude\"")
    func modelName() throws {
        let afterReply = try recorded().afterReply
        let idOnly = editing(afterReply) { $0["model", "display_name"] = nil }
        let noModel = editing(afterReply) { $0["model"] = nil }
        #expect(ClaudeStatusLine.run(input: idOnly, saved: nil, now: repliedAt).line == "claude-opus-5-5 · 5h 19% · wk 11%")
        #expect(ClaudeStatusLine.run(input: noModel, saved: nil, now: repliedAt).line == "Claude · 5h 19% · wk 11%")
    }

    @Test("an unreadable saved file is replaced, and reads as no data meanwhile")
    func unreadableSavedFile() throws {
        let corrupt = Data("{\"rate_limits\": {\"five_ho".utf8)
        #expect(ClaudeStatusLine.limits(fromSaved: corrupt) == nil)
        let run = ClaudeStatusLine.run(input: try recorded().afterReply, saved: corrupt, now: repliedAt)
        #expect(run.save.flatMap(ClaudeStatusLine.limits(fromSaved:))?.fiveHour?.usedPercent == 19)
    }

    @Test("a saved file whose capture time can't be read still shows its windows")
    func unreadableCaptureTime() throws {
        let saved = Data("""
        {"capturedAt": "a moment ago", "rate_limits": {"five_hour": {"used_percentage": 19, "resets_at": 1791708600}}}
        """.utf8)
        let section = snapshot(claudeStatusLine: ClaudeStatusLine.limits(fromSaved: saved), at: repliedAt)
        #expect(section.claude.updatedText == nil)
        #expect(section.claude.meters.map(\.percentText) == ["19%", "—", "—"])
    }

    @Test(
        "snapshot fixtures replay recorded status line JSON the way the app reads it",
        arguments: [
            ("claude-status-line", "✳ 19% · ⌘ 13%", ["19%", "11%", "34%"], "Resets in 3h 04m (1:50 AM)"),
            ("claude-status-line-near", "✳ 93% · ⌘ 13%", ["93%", "71%", "34%"], "Resets in 2h 18m (4:58 PM)"),
            ("claude-status-line-maxed", "✳ 1h 05m · ⌘ 13%", ["100%", "84%", "58%"], "Limit reached · resets in 1h 05m (3:45 PM)"),
            ("claude-status-line-reset", "✳ 64% · ⌘ 13%", ["0%", "64%", "34%"], "Reset at 2:30 PM"),
        ]
    )
    func fixtures(name: String, menuBar: String, percents: [String], fiveHourReset: String) throws {
        let fixture = try loadFixture(name)
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        #expect(snapshot.menuBar.text == menuBar)
        #expect(snapshot.claude.meters.map(\.percentText) == percents)
        #expect(snapshot.claude.meters.first?.resetText == fiveHourReset)
        #expect(snapshot.claude.plan == "Max")
    }
}
