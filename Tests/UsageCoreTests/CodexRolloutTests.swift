import Foundation
import Testing
import UsageCore

/// Reading Codex's rollout files (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`):
/// each response's usage, from the change in the session's running total,
/// at the model of the turn it belongs to.
@Suite("Codex rollouts")
struct CodexRolloutTests {
    /// The Codex chart at 12:55 AM on Sun 11 Oct, in the weekly window that
    /// resets Thu 15 Oct at 1:16 PM.
    func chart(_ entries: [UsageEntry]) throws -> CostChart {
        try #require(snapshot(codex: codex(), codexUsage: entries, at: date("2026-10-11T00:55:00-07:00")).codex.chart)
    }

    func recorded(_ name: String) throws -> [Data] {
        try fixtureLines("codex/\(name).jsonl")
    }

    @Test("a recorded session: each response counts once at its turn's model, adding up to the session's final total")
    func recordedSession() throws {
        // Recorded on this Mac, message text removed: one GPT-6-Astra
        // session over two turns, seven responses. Each response's
        // `token_usage_record` line is in the file too, and isn't counted
        // again. The last running total is 348,455 input (282,496 cached)
        // and 661 output: 349,116 tokens.
        let entries = codexUsage([try recorded("rollout-session")])
        #expect(entries.count == 7)
        #expect(Set(entries.map(\.model)) == ["gpt-6-astra"])
        #expect(entries.map(\.tokens.total).reduce(0, +) == 349_116)
        #expect(entries.map(\.tokens.cacheRead).reduce(0, +) == 282_496)
        // 65,959 uncached x $10 + 282,496 cached x $1 + 661 output x $50 = $0.975136
        let chart = try chart(entries)
        #expect(abs(chart.days[2].dollars - 0.975136) < 1e-9)
        #expect(chart.legend.map(\.valueText) == ["$0.98 · 349K tokens"])
    }

    @Test("a recorded `codex review`: the parent thread logs no usage, its review thread's counts once")
    func recordedReview() throws {
        // `codex review` writes two files with the same timestamp: the
        // parent thread, with no token counts, and the review subagent's
        // thread, which logs every response.
        let parent = try recorded("rollout-review-parent")
        let child = try recorded("rollout-review-child")
        #expect(codexUsage([parent]).isEmpty)
        let entries = codexUsage([parent, child])
        // Each response's input plus output, as its `last_token_usage` says.
        #expect(entries.map(\.tokens.total) == [11_088, 14_008, 26_428, 32_954, 35_791])
        // 31,383 uncached x $10 + 88,192 cached x $1 + 694 output x $50 = $0.436722
        let chart = try chart(entries)
        #expect(abs(chart.days[2].dollars - 0.436722) < 1e-9)
        #expect(chart.legend.map(\.valueText) == ["$0.44 · 120K tokens"])
    }

    // MARK: - Running totals

    @Test("a repeated token count adds nothing, and one with no info is skipped")
    func repeatedCount() throws {
        let first = codexTokens(input: 10_000, output: 1_000)
        let both = codexTokens(input: 30_000, output: 3_000)
        let entries = codexUsage([[
            Rollout.sessionMeta(id: "thread-1", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:01-07:00", total: nil, last: nil),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: first, last: first),
            // Codex sends the same numbers again, e.g. when only its rate limits changed.
            Rollout.tokenCount(at: "2026-10-09T10:00:06-07:00", total: first, last: first),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00", total: both, last: codexTokens(input: 20_000, output: 2_000)),
        ]])
        #expect(entries.map(\.tokens) == [
            TokenCounts(input: 10_000, output: 1_000),
            TokenCounts(input: 20_000, output: 2_000),
        ])
    }

    @Test("a running total that goes down has started over: that response counts its own usage")
    func runningTotalStartsOver() throws {
        let entries = codexUsage([[
            Rollout.sessionMeta(id: "thread-1", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: codexTokens(input: 50_000, output: 500),
                               last: codexTokens(input: 50_000, output: 500)),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00", total: codexTokens(input: 8_000, output: 80),
                               last: codexTokens(input: 7_000, output: 70)),
            Rollout.tokenCount(at: "2026-10-09T10:00:12-07:00", total: codexTokens(input: 9_000, output: 90),
                               last: codexTokens(input: 1_000, output: 10)),
        ]])
        #expect(entries.map(\.tokens) == [
            TokenCounts(input: 50_000, output: 500),
            TokenCounts(input: 7_000, output: 70),
            TokenCounts(input: 1_000, output: 10),
        ])
    }

    @Test("a response logged without a running total moves the total on, so the next one doesn't count it again")
    func countWithoutTotal() throws {
        let entries = codexUsage([[
            Rollout.sessionMeta(id: "thread-1", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: codexTokens(input: 1_000), last: codexTokens(input: 1_000)),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00", total: nil, last: codexTokens(input: 200)),
            Rollout.tokenCount(at: "2026-10-09T10:00:12-07:00", total: codexTokens(input: 1_500), last: codexTokens(input: 300)),
        ]])
        #expect(entries.map(\.tokens.input) == [1_000, 200, 300])
    }

    @Test("a running total that can't be read isn't taken for a reset: its response's own usage moves the total on")
    func unreadableTotal() throws {
        let entries = codexUsage([[
            Rollout.sessionMeta(id: "thread-1", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: codexTokens(input: 1_000), last: codexTokens(input: 1_000)),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00",
                               total: ["input_tokens": "1100", "output_tokens": 0], last: codexTokens(input: 100)),
            Rollout.tokenCount(at: "2026-10-09T10:00:12-07:00", total: codexTokens(input: 1_200), last: codexTokens(input: 100)),
        ]])
        #expect(entries.map(\.tokens.input) == [1_000, 100, 100])
    }

    @Test("a running total that drops a count it had isn't trusted; a count it never had reads as zero")
    func missingTotalField() throws {
        func total(input: Int, cached: Int?) -> [String: Any] {
            var fields: [String: Any] = ["input_tokens": input, "output_tokens": 0]
            if let cached { fields["cached_input_tokens"] = cached }
            return fields
        }
        let last = codexTokens(input: 1_000, cached: 800)
        let dropped = codexUsage([[
            Rollout.sessionMeta(id: "thread-1", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: total(input: 1_000, cached: 800), last: last),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00", total: total(input: 2_000, cached: nil), last: last),
            Rollout.tokenCount(at: "2026-10-09T10:00:12-07:00", total: total(input: 3_000, cached: 2_400), last: last),
        ]])
        #expect(dropped.map(\.tokens) == Array(repeating: TokenCounts(input: 200, cacheRead: 800), count: 3))

        // An older Codex that never logs cache writes.
        let never = codexUsage([[
            Rollout.sessionMeta(id: "thread-2", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: total(input: 1_000, cached: 800), last: nil),
            Rollout.tokenCount(at: "2026-10-09T10:00:06-07:00", total: total(input: 1_000, cached: 800), last: nil),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00", total: total(input: 2_000, cached: 1_600), last: nil),
        ]])
        #expect(never.map(\.tokens) == Array(repeating: TokenCounts(input: 200, cacheRead: 800), count: 2))
    }

    @Test("a running total that loses a count for good counts each response once, and nothing for a count sent again")
    func countGoneForGood() throws {
        let last = codexTokens(input: 1_000, cached: 800)
        let entries = codexUsage([[
            Rollout.sessionMeta(id: "thread-1", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: codexTokens(input: 1_000, cached: 800), last: last),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00", total: ["input_tokens": 2_000, "output_tokens": 0], last: last),
            Rollout.tokenCount(at: "2026-10-09T10:00:10-07:00", total: ["input_tokens": 2_000, "output_tokens": 0], last: last),
            Rollout.tokenCount(at: "2026-10-09T10:00:14-07:00", total: ["input_tokens": 3_000, "output_tokens": 0], last: last),
        ]])
        #expect(entries.map(\.tokens) == Array(repeating: TokenCounts(input: 200, cacheRead: 800), count: 3))
    }

    @Test("a running total with one count gone down has started over, even when the sum went up")
    func oneCountDown() throws {
        let entries = codexUsage([[
            Rollout.sessionMeta(id: "thread-1", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: codexTokens(input: 1_000, cached: 800),
                               last: codexTokens(input: 1_000, cached: 800)),
            Rollout.tokenCount(at: "2026-10-09T10:00:09-07:00", total: codexTokens(input: 3_000, cached: 500),
                               last: codexTokens(input: 900, cached: 500)),
        ]])
        #expect(entries.map(\.tokens) == [TokenCounts(input: 200, cacheRead: 800), TokenCounts(input: 400, cacheRead: 500)])
    }

    @Test("a file whose first running total carries earlier usage counts only that response's own")
    func carriedTotal() throws {
        let entries = codexUsage([[
            Rollout.sessionMeta(id: "thread-2", at: "2026-10-09T10:00:00-07:00"),
            Rollout.turnContext(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            Rollout.tokenCount(at: "2026-10-09T10:00:05-07:00", total: codexTokens(input: 900_000, output: 9_000),
                               last: codexTokens(input: 40_000, cached: 30_000, output: 400)),
        ]])
        #expect(entries.map(\.tokens) == [TokenCounts(input: 10_000, cacheRead: 30_000, output: 400)])
    }

    @Test("missing, extra and mistyped fields cost only what they carry; unreadable lines are skipped")
    func tolerantDecoding() throws {
        let lines = [
            #"{"timestamp":"2026-10-09T17:00:00.000Z","type":"session_meta","payload":{"id":"thread-1","new_field":1}}"#,
            // A usage before any turn says its model is "unknown".
            #"{"timestamp":"2026-10-09T17:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":10},"last_token_usage":{"input_tokens":1000,"output_tokens":10}}}}"#,
            #"{"timestamp":"2026-10-09T17:00:02.000Z","type":"turn_context","payload":{"model":"gpt-6-astra","extra":{"x":1}}}"#,
            // A mistyped running total can't be trusted, so the response's
            // own usage counts, where a mistyped count reads as zero.
            #"{"timestamp":"2026-10-09T17:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"output_tokens":"lots"},"last_token_usage":{"input_tokens":2000,"output_tokens":"lots"}}}}"#,
            // A turn whose model can't be read has an unknown model, not the last one.
            #"{"timestamp":"2026-10-09T17:00:04.000Z","type":"turn_context","payload":{"model":7}}"#,
            // No running total: the response's own usage counts.
            #"{"timestamp":"2026-10-09T17:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"output_tokens":5}}}}"#,
            // No timestamp: it moves the running total on, but can't go on the chart.
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"output_tokens":20}}}}"#,
            #"{"timestamp":"2026-10-09T17:00:07.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4100,"output_tokens":21}}}}"#,
            // Not JSON, or not ours.
            #"{"timestamp":"2026-10-09T17:00:08.000Z","type":"event_msg","payload":"#,
            #"{"timestamp":"2026-10-09T17:00:09.000Z","type":"response_item","payload":{"type":"message","content":"token_count turn_context"}}"#,
        ]
        let entries = codexUsage([lines.map { Data($0.utf8) }])
        #expect(entries.map(\.model) == ["unknown", "gpt-6-astra", "unknown", "unknown"])
        #expect(entries.map(\.tokens) == [
            TokenCounts(input: 1_000, output: 10),
            TokenCounts(input: 2_000),
            TokenCounts(input: 500, output: 5),
            TokenCounts(input: 100, output: 1),
        ])
    }

    // MARK: - Incremental scan

    let since = date("2026-10-03T14:40:00-07:00")

    func file(_ size: Int, identity: UInt64 = 1) -> RolloutScan.File {
        RolloutScan.File(path: "/s/rollout-a.jsonl", size: size, modified: date("2026-10-10T14:00:00-07:00"), identity: identity)
    }

    func bytes(_ lines: [Data]) -> Data {
        lines.reduce(Data()) { $0 + $1 + Data("\n".utf8) }
    }

    @Test("a rescan reads only the new bytes, carrying the turn's model and the running total across reads")
    func incremental() throws {
        let lines = Rollout.session([
            .turn(model: "gpt-6-luna", at: "2026-10-10T10:00:00-07:00"),
            .response(at: "2026-10-10T10:00:05-07:00", codexTokens(input: 10_000, output: 100)),
            .response(at: "2026-10-10T10:00:09-07:00", codexTokens(input: 12_000, output: 200)),
        ])
        var scan = RolloutScan()
        let first = bytes(Array(lines.prefix(3)))
        let read = scan.reads(for: [file(first.count)], since: since)
        #expect(read == [RolloutScan.Read(path: "/s/rollout-a.jsonl", offset: 0, length: first.count)])
        scan.receive(first, for: read[0])

        let all = bytes(lines)
        let next = scan.reads(for: [file(all.count)], since: since)
        #expect(next == [RolloutScan.Read(path: "/s/rollout-a.jsonl", offset: first.count, length: all.count - first.count)])
        scan.receive(all.suffix(from: first.count), for: next[0])
        #expect(scan.entries.map(\.model) == ["gpt-6-luna", "gpt-6-luna"])
        #expect(scan.entries.map(\.tokens) == [TokenCounts(input: 10_000, output: 100), TokenCounts(input: 12_000, output: 200)])
    }

    @Test("a file that was replaced is read again from the start, without double counting")
    func replacedFile() throws {
        let content = bytes(Rollout.session([
            .turn(model: "gpt-6-astra", at: "2026-10-10T10:00:00-07:00"),
            .response(at: "2026-10-10T10:00:05-07:00", codexTokens(input: 10_000, output: 100)),
            .response(at: "2026-10-10T10:00:09-07:00", codexTokens(input: 12_000, output: 200)),
        ]))
        var scan = RolloutScan()
        scan.receive(content, for: scan.reads(for: [file(content.count)], since: since)[0])
        let again = scan.reads(for: [file(content.count, identity: 2)], since: since)
        #expect(again == [RolloutScan.Read(path: "/s/rollout-a.jsonl", offset: 0, length: content.count)])
        scan.receive(content, for: again[0])
        #expect(scan.entries.count == 2)
    }

    @Test("a session file moved elsewhere, as archiving does, counts once")
    func movedFile() throws {
        let content = bytes(Rollout.session(id: "thread-9", [
            .turn(model: "gpt-6-astra", at: "2026-10-10T10:00:00-07:00"),
            .response(at: "2026-10-10T10:00:05-07:00", codexTokens(input: 10_000, output: 100)),
        ]))
        var scan = RolloutScan()
        scan.receive(content, for: scan.reads(for: [file(content.count)], since: since)[0])
        var moved = file(content.count)
        moved.path = "/archived_sessions/rollout-a.jsonl"
        scan.receive(content, for: scan.reads(for: [moved], since: since)[0])
        #expect(scan.entries.count == 1)
    }
}
