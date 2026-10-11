import Foundation
import Testing
import UsageCore

/// Reading Claude Code's transcripts: which lines count, and the incremental
/// scan that reads only what was appended since the last one.
@Suite("Claude transcripts")
struct ClaudeTranscriptTests {
    /// The last 7 local days (no weekly reading) at 11:30 PM on Sat 10 Oct.
    func chart(_ entries: [UsageEntry]) throws -> CostChart {
        let snapshot = UsageEngine.snapshot(
            from: Readings(claude: claude(weekly: nil), claudeUsage: entries),
            now: date("2026-10-10T23:30:00-07:00"),
            timeZone: losAngeles
        )
        return try #require(snapshot.claude.chart)
    }

    @Test("a recorded transcript: each reply counts once with its final counts; synthetic, user and cut-off lines don't count")
    func recordedTranscript() throws {
        // Recorded on this machine, message text removed: an Opus 5.5 reply
        // writing to the 1-hour cache; a subagent's Opus 5.5 reply logged
        // twice while it streamed (output 5, then 1,403); a Fable 5.1 reply;
        // a user line; a <synthetic> reply; a line cut off mid-write.
        var ledger = UsageLedger()
        ledger.add(ClaudeTranscript.entries(in: try Data(contentsOf: fixtureURL("claude/transcript.jsonl"))))
        #expect(ledger.count == 3)
        let chart = try chart(ledger.entries)
        // Opus 5.5: 4 x $4 + 1,796 x $8 + 119,923 x $0.20 + 406 x $20 = $0.0464886 (Fri)
        //         + 2 x $4 + 1,792 x $5 + 85,122 x $0.20 + 1,403 x $20 = $0.0540524 (Sat)
        // Fable 5.1: 2 x $10 + 6,614 x $20 + 81,381 x $0.25 + 2,413 x $50 = $0.27329525 (Sun)
        let expected = [0.27329525, 0, 0, 0, 0, 0.0464886, 0.0540524]
        #expect(zip(chart.days.map(\.dollars), expected).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(chart.legend.map(\.name) == ["Opus 5.5", "Fable 5.1"])
        #expect(chart.legend.map(\.valueText) == ["$0.10 · 210K tokens", "$0.27 · 90K tokens"])
    }

    @Test("missing, extra and mistyped fields cost only what they carry; a line with no id or time is skipped")
    func tolerantDecoding() throws {
        let lines = [
            // No cache_creation split: the writes are priced as 5-minute ones.
            #"{"type":"assistant","timestamp":"2026-10-10T10:00:00.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"cache_creation_input_tokens":200000,"new_field":{"x":1}}}}"#,
            // A mistyped count reads as zero; the others still count.
            #"{"type":"assistant","timestamp":"2026-10-10T10:01:00Z","message":{"id":"msg_2","model":"claude-opus-5-5","usage":{"output_tokens":"lots","cache_read_input_tokens":1000000}}}"#,
            // No message id: the request id identifies it instead.
            #"{"type":"assistant","timestamp":"2026-10-10T10:02:00Z","requestId":"req_3","message":{"model":"claude-opus-5-5","usage":{"output_tokens":10000}}}"#,
            // Nothing to identify it or no time: skipped.
            #"{"type":"assistant","timestamp":"2026-10-10T10:03:00Z","message":{"model":"claude-opus-5-5","usage":{"output_tokens":10000}}}"#,
            #"{"type":"assistant","message":{"id":"msg_5","model":"claude-opus-5-5","usage":{"output_tokens":10000}}}"#,
            // Not JSON at all.
            #"{"type":"assistant","message":"#,
        ]
        let entries = ClaudeTranscript.entries(in: Data(lines.joined(separator: "\n").utf8))
        #expect(entries.map(\.id) == ["msg_1", "msg_2", "req_3"])
        // 200,000 x $5 = $1.00, 1,000,000 x $0.20 = $0.20, 10,000 x $20 = $0.20
        let chart = try chart(entries)
        #expect(abs((chart.days.last?.dollars ?? 0) - 1.4) < 1e-9)
        #expect(chart.totalText == "$1.40 · 1.2M tokens")
    }

    // MARK: - Incremental scan

    let file = TranscriptScan.File(path: "/p/a.jsonl", size: 0, modified: date("2026-10-10T14:00:00-07:00"), identity: 1)
    let since = date("2026-10-03T14:40:00-07:00")

    func line(_ id: String, output: Int = 50_000) -> Data {
        transcriptLine(id: id, at: "2026-10-10T14:00:00-07:00", output: output) + Data("\n".utf8)
    }

    @Test("a rescan reads only the bytes added since the last scan")
    func readsOnlyNewBytes() {
        var scan = TranscriptScan()
        let first = line("msg_1")
        var a = file
        a.size = first.count
        #expect(scan.reads(for: [a], since: since) == [TranscriptScan.Read(path: a.path, offset: 0, length: first.count)])
        scan.receive(first, for: TranscriptScan.Read(path: a.path, offset: 0, length: first.count))
        #expect(scan.reads(for: [a], since: since).isEmpty)

        let second = line("msg_2")
        a.size += second.count
        #expect(scan.reads(for: [a], since: since) == [TranscriptScan.Read(path: a.path, offset: first.count, length: second.count)])
        scan.receive(second, for: TranscriptScan.Read(path: a.path, offset: first.count, length: second.count))
        #expect(scan.entries.map(\.id) == ["msg_1", "msg_2"])
    }

    @Test("a line still being written is read again once it's complete")
    func partialLine() {
        var scan = TranscriptScan()
        let whole = line("msg_1")
        let partial = line("msg_2").dropLast(20)
        var a = file
        a.size = whole.count + partial.count
        let read = TranscriptScan.Read(path: a.path, offset: 0, length: a.size)
        #expect(scan.reads(for: [a], since: since) == [read])
        scan.receive(whole + partial, for: read)
        #expect(scan.entries.map(\.id) == ["msg_1"])

        a.size = whole.count + line("msg_2").count
        #expect(scan.reads(for: [a], since: since) == [TranscriptScan.Read(path: a.path, offset: whole.count, length: line("msg_2").count)])
        scan.receive(line("msg_2"), for: TranscriptScan.Read(path: a.path, offset: whole.count, length: line("msg_2").count))
        #expect(scan.entries.map(\.id) == ["msg_1", "msg_2"])
    }

    @Test("a file that shrank or was replaced is read again from the start, without double counting")
    func replacedFile() {
        var scan = TranscriptScan()
        let content = line("msg_1") + line("msg_2")
        var a = file
        a.size = content.count
        scan.receive(content, for: scan.reads(for: [a], since: since)[0])

        // Rewritten in place with less in it.
        a.size = line("msg_1").count
        #expect(scan.reads(for: [a], since: since) == [TranscriptScan.Read(path: a.path, offset: 0, length: a.size)])

        // Replaced by a new file under the same name.
        var b = file
        b.size = content.count
        b.identity = 2
        let read = scan.reads(for: [b], since: since)
        #expect(read == [TranscriptScan.Read(path: a.path, offset: 0, length: content.count)])
        scan.receive(content, for: read[0])
        #expect(scan.entries.map(\.id) == ["msg_1", "msg_2"])
    }

    @Test("files last changed before the window aren't read, and older replies are forgotten")
    func outsideWindow() {
        var scan = TranscriptScan()
        var old = file
        old.path = "/p/old.jsonl"
        old.size = 100
        old.modified = date("2026-10-01T09:00:00-07:00")
        #expect(scan.reads(for: [old], since: since).isEmpty)

        var a = file
        let content = transcriptLine(id: "msg_old", at: "2026-10-01T09:00:00-07:00") + Data("\n".utf8) + line("msg_new")
        a.size = content.count
        scan.receive(content, for: scan.reads(for: [a], since: since)[0])
        #expect(scan.entries.map(\.id) == ["msg_new"])
    }

    @Test("the same reply in two files counts once")
    func sameReplyInTwoFiles() {
        var scan = TranscriptScan()
        var a = file
        var b = file
        b.path = "/p/b/subagents/agent-1.jsonl"
        b.identity = 2
        a.size = line("msg_1").count
        b.size = line("msg_1").count
        for read in scan.reads(for: [a, b], since: since) {
            scan.receive(line("msg_1"), for: read)
        }
        #expect(scan.entries.map(\.id) == ["msg_1"])
    }
}
