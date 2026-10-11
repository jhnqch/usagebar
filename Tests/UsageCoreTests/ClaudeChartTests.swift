import Foundation
import Testing
import UsageCore

/// The weekly cost chart: one bar per local calendar day of the current
/// weekly window (its reset minus 7 days, to its reset), stacked by model in
/// API-equivalent dollars, with days still to come drawn empty.
@Suite("Claude cost chart")
struct ClaudeChartTests {
    func chart(_ lines: [Data], limits: ClaudeLimits? = claude(), at time: Date = now, timeZone: TimeZone = losAngeles) throws -> CostChart {
        let snapshot = UsageEngine.snapshot(
            from: Readings(claude: limits, claudeUsage: claudeUsage(lines)),
            now: time,
            timeZone: timeZone
        )
        return try #require(snapshot.claude.chart)
    }

    @Test("the chart covers the weekly window, one bar per local day, with days to come empty")
    func window() throws {
        // The weekly window resets Tue 13 Oct at 7:00 AM, so it started Tue 6
        // Oct at 7:00 AM. It's Sat 10 Oct, 2:40 PM.
        let chart = try chart([])
        #expect(chart.title == "This week")
        #expect(chart.rangeText == "Tue 7 AM to Tue 7 AM · 2d 16h left")
        #expect(chart.days.map(\.label) == ["Tue", "Wed", "Thu", "Fri", "Today", "Sun", "Mon", "Tue"])
        #expect(chart.days.map(\.isFuture) == [false, false, false, false, false, true, true, true])
        #expect(chart.days.map(\.isToday) == [false, false, false, false, true, false, false, false])
        #expect(chart.totalText == "$0.00 · 0 tokens")
        #expect(chart.legend.isEmpty)
    }

    @Test("each day stacks its models' dollars; the legend shows each model's dollars and tokens")
    func stackedDays() throws {
        // Output only, per million: Opus 5.5 $20, Fable 5.1 $50, Haiku 5.5 $0.50.
        let chart = try chart([
            transcriptLine(id: "msg_early", at: "2026-10-06T06:59:00-07:00", output: 50_000),  // before the window
            transcriptLine(id: "msg_1", at: "2026-10-06T07:00:00-07:00", output: 25_000),      // Tue $0.50
            transcriptLine(id: "msg_2", at: "2026-10-07T10:00:00-07:00", output: 50_000),      // Wed $1.00
            transcriptLine(id: "msg_3", at: "2026-10-07T11:00:00-07:00", model: "claude-fable-5-1", output: 50_000),  // Wed $2.50
            transcriptLine(id: "msg_4", at: "2026-10-09T09:00:00-07:00", model: "claude-haiku-5-5", output: 1_000_000), // Fri $0.50
            transcriptLine(id: "msg_5", at: "2026-10-10T14:00:00-07:00", output: 100_000),     // Today $2.00
        ])
        #expect(chart.days.map(\.dollars) == [0.5, 3.5, 0, 0.5, 2, 0, 0, 0])
        #expect(chart.days[1].segments == [
            CostChart.Segment(model: "claude-opus-5-5", series: 0, dollars: 1),
            CostChart.Segment(model: "claude-fable-5-1", series: 1, dollars: 2.5),
        ])
        #expect(chart.days[3].segments == [CostChart.Segment(model: "claude-haiku-5-5", series: 3, dollars: 0.5)])
        #expect(chart.days[1].detailText == "Wed Oct 7 · $3.50 · 100K tokens")
        #expect(chart.days[6].detailText == "Mon Oct 12 · to come")
        #expect(chart.legend == [
            CostChart.LegendRow(model: "claude-opus-5-5", name: "Opus 5.5", valueText: "$3.50 · 175K tokens", series: 0),
            CostChart.LegendRow(model: "claude-fable-5-1", name: "Fable 5.1", valueText: "$2.50 · 50K tokens", series: 1),
            CostChart.LegendRow(model: "claude-haiku-5-5", name: "Haiku 5.5", valueText: "$0.50 · 1M tokens", series: 3),
        ])
        #expect(chart.totalText == "$6.50 · 1.2M tokens")
    }

    @Test("a model missing from the price table adds tokens but no dollars, and the legend flags it")
    func unknownModel() throws {
        let chart = try chart([
            transcriptLine(id: "msg_1", at: "2026-10-08T10:00:00-07:00", output: 100_000),
            transcriptLine(id: "msg_2", at: "2026-10-08T11:00:00-07:00", model: "claude-zeta-1",
                           input: 200_000, read: 1_000_000),
        ])
        #expect(chart.days[2].dollars == 2)
        #expect(chart.days[2].segments.map(\.model) == ["claude-opus-5-5"])
        #expect(chart.legend.last == CostChart.LegendRow(
            model: "claude-zeta-1", name: "claude-zeta-1", valueText: "no price · 1.2M tokens", series: nil
        ))
        #expect(chart.totalText == "$2.00 · 1.3M tokens")
    }

    @Test("replies are bucketed by local calendar day, not UTC, either side of midnight")
    func midnight() throws {
        let chart = try chart([
            // 11:59 PM Wed in Los Angeles is already Thu in UTC.
            transcriptLine(id: "msg_1", at: "2026-10-07T23:59:30-07:00", output: 50_000),
            transcriptLine(id: "msg_2", at: "2026-10-08T00:00:30-07:00", output: 100_000),
        ])
        #expect(chart.days.map(\.dollars) == [0, 1, 2, 0, 0, 0, 0, 0])
    }

    @Test("across the end of daylight saving time, the 25-hour Sunday keeps all its replies")
    func daylightSaving() throws {
        // Clocks go back at 2 AM on Sun 1 Nov 2026. The window resets Wed 4
        // Nov at 7:00 AM PST; 7 x 24 hours earlier is 8:00 AM PDT on Wed 28 Oct.
        let limits = claude(weeklyResetsAt: date("2026-11-04T07:00:00-08:00"))
        let chart = try chart([
            transcriptLine(id: "msg_1", at: "2026-11-01T01:30:00-07:00", output: 50_000),   // Sun, first 1:30 AM
            transcriptLine(id: "msg_2", at: "2026-11-01T01:30:00-08:00", output: 50_000),   // Sun, second 1:30 AM
            transcriptLine(id: "msg_3", at: "2026-11-01T23:30:00-08:00", output: 50_000),   // Sun, late
            transcriptLine(id: "msg_4", at: "2026-11-02T00:30:00-08:00", output: 100_000),  // Mon
        ], limits: limits, at: date("2026-11-02T12:00:00-08:00"))
        #expect(chart.rangeText == "Wed 8 AM to Wed 7 AM · 1d 19h left")
        #expect(chart.days.map(\.label) == ["Wed", "Thu", "Fri", "Sat", "Sun", "Today", "Tue", "Wed"])
        #expect(chart.days.map(\.dollars) == [0, 0, 0, 0, 3, 2, 0, 0])
    }

    @Test("a reset a fraction of a second before midnight doesn't add a sliver of a day")
    func resetJustBeforeMidnight() throws {
        // The usage endpoint reports resets like 06:59:59.82 UTC, a moment
        // before midnight in Los Angeles.
        let limits = claude(weeklyResetsAt: date("2026-10-16T06:59:59Z").addingTimeInterval(0.82))
        let chart = try chart([], limits: limits)
        #expect(chart.rangeText == "Fri 12 AM to Fri 12 AM · 5d 9h left")
        #expect(chart.days.map(\.label) == ["Fri", "Today", "Sun", "Mon", "Tue", "Wed", "Thu"])
    }

    @Test("a weekly window whose reset has passed rolls on to the next week")
    func passedWeeklyReset() throws {
        let chart = try chart([], limits: claude(weeklyResetsAt: date("2026-10-06T07:00:00-07:00")))
        #expect(chart.rangeText == "Tue 7 AM to Tue 7 AM · 2d 16h left")
        #expect(chart.days.count == 8)
    }

    @Test("with no weekly reading, the chart shows the last 7 local days and says so")
    func noWeeklyReading() throws {
        let chart = try chart([
            transcriptLine(id: "msg_1", at: "2026-10-04T00:10:00-07:00", output: 50_000),
            transcriptLine(id: "msg_2", at: "2026-10-03T23:50:00-07:00", output: 50_000),  // 8 days ago
        ], limits: claude(weekly: nil))
        #expect(chart.title == "Last 7 days")
        #expect(chart.rangeText == "No weekly reading yet")
        #expect(chart.days.map(\.label) == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Today"])
        #expect(chart.days.map(\.isFuture) == Array(repeating: false, count: 7))
        #expect(chart.days.map(\.dollars) == [1, 0, 0, 0, 0, 0, 0])
    }

    @Test("each model line keeps its colour; another version of a line takes the next free one")
    func series() throws {
        let chart = try chart([
            transcriptLine(id: "msg_1", at: "2026-10-08T10:00:00-07:00", model: "claude-sonnet-5-5", output: 10_000),
            transcriptLine(id: "msg_2", at: "2026-10-08T10:00:00-07:00", model: "claude-opus-5", output: 10_000),
            transcriptLine(id: "msg_3", at: "2026-10-08T10:00:00-07:00", model: "claude-opus-5-5", output: 10_000),
        ])
        #expect(chart.legend.map(\.name) == ["Opus 5.5", "Sonnet 5.5", "Opus 5"])
        #expect(chart.legend.map(\.series) == [0, 2, 4])
    }

    @Test("a window that starts just before midnight labels its first bar with the day that holds it")
    func firstBarLabel() throws {
        // Starts Tue 6 Oct at 11:30 PM: that half hour joins Wednesday's bar.
        let chart = try chart([
            transcriptLine(id: "msg_1", at: "2026-10-06T23:45:00-07:00", output: 50_000),
            transcriptLine(id: "msg_2", at: "2026-10-07T12:00:00-07:00", output: 50_000),
        ], limits: claude(weeklyResetsAt: date("2026-10-13T23:30:00-07:00")))
        #expect(chart.days.map(\.label) == ["Wed", "Thu", "Fri", "Today", "Sun", "Mon", "Tue"])
        #expect(chart.days[0].dollars == 2)
        #expect(chart.days[0].detailText == "Wed Oct 7 · $2.00 · 100K tokens")
    }

    @Test(
        "a bar's segments and the gaps between them add up to the bar's height, however small",
        arguments: [
            // day's share of the tallest bar, segments
            (1.0, 3), (0.5, 2), (0.01, 6), (0.001, 1),
        ]
    )
    func stackFitsBar(share: Double, segments: Int) {
        let day = CostChart.Day(
            id: now, label: "Wed", isToday: false, isFuture: false,
            segments: (0..<segments).map { CostChart.Segment(model: "m\($0)", series: $0, dollars: share * 100 / Double(segments)) },
            dollars: share * 100,
            detailText: ""
        )
        let stack = day.stack(barHeight: 64, maxDollars: 100, gap: 2)
        // The bar is proportional to the day's dollars, at least 2 points.
        let height = max(64 * share, 2)
        let drawn = stack.heights.reduce(0, +) + stack.gap * Double(segments - 1)
        #expect(abs(drawn - height) < 1e-9)
        #expect(stack.heights.count == segments)
        #expect(stack.gap <= 2)
        if share >= 0.5 { #expect(stack.gap == 2) }
    }
}
