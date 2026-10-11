import Foundation
import Testing
import UsageCore

/// What Claude Code's usage would have cost at API prices: each message's
/// tokens priced per model, per kind of token.
@Suite("Claude cost")
struct ClaudeCostTests {
    @Test("the session line prices each kind of token at its model's rate")
    func costArithmetic() {
        // Opus 5.5 per million tokens: $4 input, $5 5-minute cache write,
        // $8 1-hour cache write, $0.20 cache read, $20 output. So:
        // 1,000 input $0.004 + 10,000 5m $0.05 + 200,000 1h $1.60
        // + 2,000,000 read $0.40 + 50,000 output $1.00 = $3.054,
        // 2,261,000 tokens.
        let usage = claudeUsage([
            transcriptLine(id: "msg_1", at: "2026-10-10T14:00:00-07:00",
                           input: 1_000, write5m: 10_000, write1h: 200_000, read: 2_000_000, output: 50_000),
        ])
        let meter = snapshot(claude: claude(), claudeUsage: usage).claude.meters[0]
        #expect(meter.usageText == "$3.05 · 2.3M tokens this session")
    }

    @Test("a reply logged once per streamed block, or copied into a resumed session, counts once with its final counts")
    func duplicates() {
        // Each streamed copy repeats the input counts and carries the output
        // so far. Counted once: 100,000 cache reads $0.02 + 1,400 output
        // $0.028 = $0.048, 101,400 tokens. Counted per line, it would be
        // $0.10 and 302K tokens.
        let usage = claudeUsage([
            transcriptLine(id: "msg_1", at: "2026-10-10T14:00:00-07:00", read: 100_000, output: 5),
            transcriptLine(id: "msg_1", at: "2026-10-10T14:00:09-07:00", read: 100_000, output: 1_400),
            transcriptLine(id: "msg_1", at: "2026-10-10T14:30:00-07:00", read: 100_000, output: 1_400),
        ])
        #expect(usage.count == 1)
        #expect(usage.first?.timestamp == date("2026-10-10T14:00:00-07:00"))
        let meter = snapshot(claude: claude(), claudeUsage: usage).claude.meters[0]
        #expect(meter.usageText == "$0.05 · 101K tokens this session")
    }

    @Test("the session counts only replies since the 5-hour window started")
    func sessionWindow() {
        // The window resets at 4:58 PM, so it started at 11:58 AM.
        let usage = claudeUsage([
            transcriptLine(id: "msg_before", at: "2026-10-10T11:57:59-07:00", output: 50_000),
            transcriptLine(id: "msg_in", at: "2026-10-10T11:58:00-07:00", output: 25_000),
        ])
        #expect(snapshot(claude: claude(), claudeUsage: usage).claude.meters[0].usageText == "$0.50 · 25K tokens this session")
        // No 5-hour reading: no session line.
        #expect(snapshot(claude: claude(fiveHour: nil), claudeUsage: usage).claude.meters[0].usageText == nil)
        // Only the 5-hour meter has one.
        #expect(snapshot(claude: claude(), claudeUsage: usage).claude.meters.dropFirst().allSatisfy { $0.usageText == nil })
    }

    @Test("after the 5-hour reset passes, the session counts from the reset")
    func passedSessionReset() {
        let usage = claudeUsage([
            transcriptLine(id: "msg_old", at: "2026-10-10T13:00:00-07:00", output: 50_000),
            transcriptLine(id: "msg_new", at: "2026-10-10T14:10:00-07:00", output: 5_000),
        ])
        let limits = claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T14:00:00-07:00"))
        #expect(snapshot(claude: limits, claudeUsage: usage).claude.meters[0].usageText == "$0.10 · 5K tokens this session")
    }

    @Test("once the 5-hour reset is more than 5 hours old, the session line hides rather than span sessions")
    func staleSessionReset() {
        // The session after a 9:00 AM reset started at its first reply and
        // has ended by 2:40 PM; where the next one started isn't known.
        let usage = claudeUsage([
            transcriptLine(id: "msg_1", at: "2026-10-10T09:30:00-07:00", output: 50_000),
            transcriptLine(id: "msg_2", at: "2026-10-10T14:10:00-07:00", output: 5_000),
        ])
        let limits = claude(fiveHourResetsAt: date("2026-10-10T09:00:00-07:00"))
        #expect(snapshot(claude: limits, claudeUsage: usage).claude.meters[0].usageText == nil)
        #expect(snapshot(claude: limits, claudeUsage: usage, at: date("2026-10-10T14:00:00-07:00")).claude.meters[0].usageText
            == "$1.00 · 50K tokens this session")
    }

    @Test("Haiku 5.5 charges more for a prompt over 100,000 tokens, cache reads included")
    func longContext() {
        // Up to 100,000: $0.01 read, $0.50 output. Over: $0.05 read, $2.50 output.
        let short = claudeUsage([transcriptLine(id: "msg_1", at: "2026-10-10T14:00:00-07:00", model: "claude-haiku-5-5",
                                                read: 100_000, output: 1_000_000)])
        let long = claudeUsage([transcriptLine(id: "msg_1", at: "2026-10-10T14:00:00-07:00", model: "claude-haiku-5-5",
                                               input: 1, read: 100_000, output: 1_000_000)])
        // 100,000 x $0.01 = $0.001 + 1,000,000 x $0.50 = $0.50
        #expect(snapshot(claude: claude(), claudeUsage: short).claude.meters[0].usageText == "$0.50 · 1.1M tokens this session")
        // 1 x $0.50 + 100,000 x $0.05 = $0.005 + 1,000,000 x $2.50 = $2.505
        #expect(snapshot(claude: claude(), claudeUsage: long).claude.meters[0].usageText == "$2.51 · 1.1M tokens this session")
    }

    @Test("fast mode prices Opus 5.5 at $8 / $40, with the cache multipliers on top")
    func fastMode() {
        // 100,000 1-hour writes at 2 x $8 = $1.60 + 50,000 output at $40 = $2.00.
        let usage = claudeUsage([transcriptLine(id: "msg_1", at: "2026-10-10T14:00:00-07:00",
                                                write1h: 100_000, output: 50_000, speed: "fast")])
        #expect(snapshot(claude: claude(), claudeUsage: usage).claude.meters[0].usageText == "$3.60 · 150K tokens this session")
    }

    @Test(
        "the price table has every current Claude model, at the pricing page's rates",
        arguments: [
            // id, input, 5m write, 1h write, cache read, output ($ per million tokens)
            ("claude-fable-5-1", 10.0, 12.5, 20.0, 0.25, 50.0),
            ("claude-mythos-5-1", 10, 12.5, 20, 0.25, 50),
            ("claude-fable-5", 10, 12.5, 20, 1, 50),
            ("claude-opus-5-5", 4, 5, 8, 0.20, 20),
            ("claude-opus-5", 5, 6.25, 10, 0.50, 25),
            ("claude-opus-4-8", 5, 6.25, 10, 0.50, 25),
            ("claude-opus-4-7", 5, 6.25, 10, 0.50, 25),
            ("claude-opus-4-6", 5, 6.25, 10, 0.50, 25),
            ("claude-sonnet-5-5", 2, 2.5, 4, 0.10, 10),
            ("claude-sonnet-5", 2, 2.5, 4, 0.20, 10),
            ("claude-sonnet-4-6", 3, 3.75, 6, 0.30, 15),
            ("claude-haiku-5-5", 0.10, 0.125, 0.20, 0.01, 0.50),
            ("claude-haiku-4-5-20251001", 1, 1.25, 2, 0.10, 5),
        ]
    )
    func priceTable(model: String, input: Double, write5m: Double, write1h: Double, read: Double, output: Double) throws {
        let rates = try #require(PriceTable.claude.price(for: model)).rates
        #expect(rates == TokenRates(input: input, cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: read, output: output))
    }
}
