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
}
