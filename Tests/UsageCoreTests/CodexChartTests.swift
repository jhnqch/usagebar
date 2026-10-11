import Foundation
import Testing
import UsageCore

/// The Codex cost chart: the same chart as Claude's, over Codex's own weekly
/// window (its weekly reset minus 7 days, to the reset), from Codex's
/// rollout files priced at OpenAI's API rates.
@Suite("Codex cost chart")
struct CodexChartTests {
    func chart(_ files: [[Data]], limits: CodexLimits? = codex(), at time: Date = now) throws -> CostChart {
        try #require(snapshot(codex: limits, codexUsage: codexUsage(files), at: time).codex.chart)
    }

    @Test("the chart covers Codex's weekly window, one bar per local day, with days to come empty")
    func window() throws {
        // Codex's weekly window resets Thu 15 Oct at 1:16 PM, so it started
        // Thu 8 Oct at 1:16 PM. It's Sat 10 Oct, 2:40 PM.
        let chart = try chart([])
        #expect(chart.title == "This week")
        #expect(chart.rangeText == "Thu 1:16 PM to Thu 1:16 PM · 4d 22h left")
        #expect(chart.days.map(\.label) == ["Thu", "Fri", "Today", "Sun", "Mon", "Tue", "Wed", "Thu"])
        #expect(chart.days.map(\.isFuture) == [false, false, false, true, true, true, true, true])
        #expect(chart.totalText == "$0.00 · 0 tokens")
        #expect(chart.legend.isEmpty)
    }

    @Test("the window is the weekly one, matched by its length, whichever slot it came in")
    func weeklyWindowByLength() throws {
        let plus = CodexLimits(plan: "plus", capturedAt: now, windows: [
            CodexWindow(usedPercent: 38, windowMinutes: 300, resetsAt: date("2026-10-10T16:58:00-07:00")),
            CodexWindow(usedPercent: 6, windowMinutes: 10080, resetsAt: date("2026-10-15T13:16:00-07:00")),
        ])
        #expect(try chart([], limits: plus).rangeText == "Thu 1:16 PM to Thu 1:16 PM · 4d 22h left")
    }

    @Test("with no weekly reading, the chart shows the last 7 local days and says so")
    func noWeeklyReading() throws {
        let fiveHourOnly = CodexLimits(plan: "plus", capturedAt: now, windows: [
            CodexWindow(usedPercent: 38, windowMinutes: 300, resetsAt: date("2026-10-10T16:58:00-07:00")),
        ])
        for limits in [nil, fiveHourOnly] {
            let chart = try chart([], limits: limits)
            #expect(chart.title == "Last 7 days")
            #expect(chart.rangeText == "No weekly reading yet")
            #expect(chart.days.map(\.label) == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Today"])
        }
    }

    @Test("each response is priced at its turn's model: uncached input, cached input, cache writes and output with reasoning")
    func pricedByTurnModel() throws {
        // GPT-6-Astra per million: $10 input, $1 cached input, $12.50 cache
        // writes, $50 output. Cached input and cache writes are part of the
        // input count, reasoning part of the output count. So 20,000
        // uncached $0.20 + 60,000 cached $0.06 + 20,000 written $0.25
        // + 20,000 output $1.00 = $1.51, 120,000 tokens.
        // GPT-6-Luna: $0.10 input, $0.50 output. 200,000 input $0.02
        // + 1M output $0.50 = $0.52.
        let chart = try chart([Rollout.session([
            .turn(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            .response(at: "2026-10-09T10:00:05-07:00", codexTokens(input: 100_000, cached: 60_000, write: 20_000, output: 20_000, reasoning: 5_000)),
            .turn(model: "gpt-6-luna", at: "2026-10-09T11:00:00-07:00"),
            .response(at: "2026-10-09T11:00:05-07:00", codexTokens(input: 200_000, output: 1_000_000)),
        ])])
        #expect(chart.days.map { ($0.dollars * 100).rounded() / 100 } == [0, 2.03, 0, 0, 0, 0, 0, 0])
        #expect(chart.days[1].segments == [
            CostChart.Segment(model: "gpt-6-astra", series: 0, dollars: 1.51),
            CostChart.Segment(model: "gpt-6-luna", series: 3, dollars: 0.52),
        ])
        #expect(chart.days[1].detailText == "Fri Oct 9 · $2.03 · 1.3M tokens")
        #expect(chart.legend == [
            CostChart.LegendRow(model: "gpt-6-astra", name: "GPT-6-Astra", valueText: "$1.51 · 120K tokens", series: 0),
            CostChart.LegendRow(model: "gpt-6-luna", name: "GPT-6-Luna", valueText: "$0.52 · 1.2M tokens", series: 3),
        ])
    }

    @Test("usage outside the weekly window doesn't count; usage is bucketed by local day")
    func bucketing() throws {
        // GPT-6-Astra output at $50 per million.
        let chart = try chart([Rollout.session([
            .turn(model: "gpt-6-astra", at: "2026-10-08T13:00:00-07:00"),
            .response(at: "2026-10-08T13:15:59-07:00", codexTokens(output: 100_000)),  // before the window
            .response(at: "2026-10-08T13:16:00-07:00", codexTokens(output: 10_000)),   // Thu $0.50
            .response(at: "2026-10-08T23:59:30-07:00", codexTokens(output: 20_000)),   // Thu $1.00
            .response(at: "2026-10-09T00:00:30-07:00", codexTokens(output: 40_000)),   // Fri $2.00
        ])])
        #expect(chart.days.map(\.dollars) == [1.5, 2, 0, 0, 0, 0, 0, 0])
        #expect(chart.totalText == "$3.50 · 70K tokens")
    }

    @Test("a model missing from the price table adds tokens but no dollars, and the legend flags it")
    func unknownModel() throws {
        let chart = try chart([Rollout.session([
            .turn(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
            .response(at: "2026-10-09T10:00:05-07:00", codexTokens(output: 20_000)),
            .turn(model: "codex-auto-review", at: "2026-10-09T11:00:00-07:00"),
            .response(at: "2026-10-09T11:00:05-07:00", codexTokens(input: 1_200_000, cached: 1_000_000, output: 100_000)),
        ])])
        #expect(chart.days[1].dollars == 1)
        #expect(chart.days[1].segments.map(\.model) == ["gpt-6-astra"])
        #expect(chart.legend.last == CostChart.LegendRow(
            model: "codex-auto-review", name: "codex-auto-review", valueText: "no price · 1.3M tokens", series: nil
        ))
        #expect(chart.totalText == "$1.00 · 1.3M tokens")
    }

    @Test("each Codex model line keeps its colour; another version of a line takes the next free one")
    func series() throws {
        let chart = try chart([Rollout.session([
            .turn(model: "gpt-6-sol", at: "2026-10-09T10:00:00-07:00"),
            .response(at: "2026-10-09T10:00:05-07:00", codexTokens(output: 10_000)),
            .turn(model: "gpt-6.1-sol", at: "2026-10-09T10:01:00-07:00"),
            .response(at: "2026-10-09T10:01:05-07:00", codexTokens(output: 10_000)),
            .turn(model: "gpt-6-astra", at: "2026-10-09T10:02:00-07:00"),
            .response(at: "2026-10-09T10:02:05-07:00", codexTokens(output: 10_000)),
        ])])
        #expect(chart.legend.map(\.name) == ["GPT-6-Astra", "GPT-6.1-Sol", "GPT-6-Sol"])
        #expect(chart.legend.map(\.series) == [0, 2, 4])
    }

    @Test("Claude's chart and Codex's each show only their own usage")
    func servicesStaySeparate() throws {
        let section = snapshot(
            claude: claude(),
            codex: codex(),
            claudeUsage: claudeUsage([transcriptLine(id: "msg_1", at: "2026-10-09T10:00:00-07:00", output: 50_000)]),
            codexUsage: codexUsage([Rollout.session([
                .turn(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
                .response(at: "2026-10-09T10:00:05-07:00", codexTokens(output: 20_000)),
            ])])
        )
        #expect(section.claude.chart?.legend.map(\.model) == ["claude-opus-5-5"])
        #expect(section.codex.chart?.legend.map(\.model) == ["gpt-6-astra"])
    }

    @Test("a prompt over 272,000 input tokens is priced at the long-context rates")
    func longContext() throws {
        // GPT-6-Astra up to 272K: $10 input, $50 output. Over: $20, $75.
        func dollars(input: Int) throws -> Double {
            try chart([Rollout.session([
                .turn(model: "gpt-6-astra", at: "2026-10-09T10:00:00-07:00"),
                .response(at: "2026-10-09T10:00:05-07:00", codexTokens(input: input, output: 10_000)),
            ])]).days[1].dollars
        }
        // 272,000 x $10 = $2.72 + 10,000 x $50 = $0.50
        #expect(abs(try dollars(input: 272_000) - 3.22) < 1e-9)
        // 272,001 x $20 = $5.44002 + 10,000 x $75 = $0.75
        #expect(abs(try dollars(input: 272_001) - 6.19002) < 1e-9)
    }

    @Test(
        "the price table has the models Codex offers, at OpenAI's standard rates",
        arguments: [
            // id, input, cached input, cache write, output ($ per million tokens)
            ("gpt-6-astra", 10.0, 1.0, 12.5, 50.0),
            ("gpt-6.1-sol", 2, 0.10, 2.5, 10),
            ("gpt-6-sol", 2, 0.20, 2.5, 10),
            ("gpt-6-luna", 0.10, 0.01, 0.125, 0.50),
            ("gpt-5.6-sol", 4, 0.40, 5, 20),
            ("gpt-5.6-terra", 2, 0.20, 2.5, 12),
            ("gpt-5.6-luna", 0.20, 0.02, 0.25, 1.20),
            // No cache-write price: writes cost the same as input.
            ("gpt-5.5", 5, 0.50, 5, 30),
            ("gpt-5.3-codex", 1.75, 0.175, 1.75, 14),
        ]
    )
    func priceTable(model: String, input: Double, cached: Double, write: Double, output: Double) throws {
        let rates = try #require(PriceTable.codex.price(for: model)).rates
        #expect(rates == TokenRates(input: input, cacheWrite5m: write, cacheWrite1h: write, cacheRead: cached, output: output))
    }
}
