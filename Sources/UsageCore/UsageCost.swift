import Foundation

/// Usage priced in API-equivalent dollars: the session line and the weekly
/// chart.
enum UsageCost {
    static let fiveHours: TimeInterval = 5 * 60 * 60

    /// "$4.12 · 1.9M tokens this session" for the current 5-hour window
    /// (its reset minus 5 hours, up to now), or nil without a reading. Once
    /// the reset has passed, the next session started after it, so it counts
    /// from the reset until fresh numbers arrive.
    static func session(_ usage: [UsageEntry], window: LimitReading?, now: Date, prices: PriceTable) -> String? {
        guard let window else { return nil }
        let start = window.resetsAt > now ? window.resetsAt - fiveHours : window.resetsAt
        let entries = usage.filter { $0.timestamp >= start }
        let total = Total(entries, prices: prices)
        return "\(total.text) this session"
    }

    static let week: TimeInterval = 7 * 24 * 60 * 60

    /// The weekly chart. With a weekly reading it covers that window: its
    /// reset minus 7 days, to its reset (rolled on a week at a time once the
    /// reset has passed). Without one, the last 7 local days.
    static func weeklyChart(_ usage: [UsageEntry], weekly: LimitReading?, clock: Clock, prices: PriceTable) -> CostChart {
        let now = clock.now
        let calendar = clock.calendar
        let window: DateInterval
        let title: String
        let rangeText: String
        if let weekly, let end = currentWeekEnd(resetsAt: weekly.resetsAt, now: now) {
            window = DateInterval(start: end - week, end: end)
            title = "This week"
            rangeText = "\(clock.dayAndHour(window.start)) to \(clock.dayAndHour(end)) · \(clock.countdown(to: end)) left"
        } else {
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today - 6 * 86_400
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today + 86_400
            window = DateInterval(start: start, end: end)
            title = "Last 7 days"
            rangeText = "No weekly reading yet"
        }

        let entries = usage.filter { window.start <= $0.timestamp && $0.timestamp < window.end }
        let models = Dictionary(grouping: entries, by: \.model)
        let series = seriesSlots(for: Array(models.keys), prices: prices)

        let days = dayBuckets(window, calendar: calendar).map { (bucket: DateInterval, day: Date) in
            let dayEntries = entries.filter { bucket.start <= $0.timestamp && $0.timestamp < bucket.end }
            let isFuture = bucket.start > now
            let isToday = bucket.start <= now && now < bucket.end
            let segments = Dictionary(grouping: dayEntries, by: \.model)
                .compactMap { model, entries -> CostChart.Segment? in
                    guard let slot = series[model] else { return nil }
                    let total = Total(entries, prices: prices)
                    return total.dollars > 0 ? CostChart.Segment(model: model, series: slot, dollars: total.dollars) : nil
                }
                .sorted { ($0.series, $0.model) < ($1.series, $1.model) }
            let total = Total(dayEntries, prices: prices)
            return CostChart.Day(
                id: bucket.start,
                label: isToday ? "Today" : clock.weekday(day),
                isToday: isToday,
                isFuture: isFuture,
                segments: segments,
                dollars: segments.reduce(0) { $0 + $1.dollars },
                detailText: isFuture ? "\(clock.dayAndDate(day)) · to come" : "\(clock.dayAndDate(day)) · \(total.text)"
            )
        }

        let legend = models
            .map { model, entries in (row: legendRow(model, entries, series: series[model], prices: prices), tokens: Total(entries, prices: prices).tokens) }
            .sorted(by: legendOrder)
            .map(\.row)

        return CostChart(
            title: title,
            rangeText: rangeText,
            totalText: Total(entries, prices: prices).text,
            days: days,
            legend: legend
        )
    }

    private static func legendRow(_ model: String, _ entries: [UsageEntry], series: Int?, prices: PriceTable) -> CostChart.LegendRow {
        let total = Total(entries, prices: prices)
        let price = prices.price(for: model)
        return CostChart.LegendRow(
            model: model,
            name: price?.name ?? model,
            valueText: price == nil ? "no price · \(tokenText(total.tokens)) tokens" : total.text,
            series: series
        )
    }

    /// Priced models in stacking order, then models with no price, most
    /// tokens first.
    private static func legendOrder(_ lhs: (row: CostChart.LegendRow, tokens: Int), _ rhs: (row: CostChart.LegendRow, tokens: Int)) -> Bool {
        switch (lhs.row.series, rhs.row.series) {
        case let (l?, r?): return (l, lhs.row.model) < (r, rhs.row.model)
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.tokens != rhs.tokens ? lhs.tokens > rhs.tokens : lhs.row.model < rhs.row.model
        }
    }

    /// The end of the weekly window that holds `now`. Resets come rounded
    /// differently by each source (06:59:59.82 or 07:00:00), so to the
    /// nearest minute.
    private static func currentWeekEnd(resetsAt: Date, now: Date) -> Date? {
        let reset = Date(timeIntervalSinceReferenceDate: (resetsAt.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        guard reset > now else {
            let weeksPassed = ((now.timeIntervalSince(reset)) / week).rounded(.down) + 1
            guard weeksPassed.isFinite, weeksPassed < 10_000 else { return nil }
            return reset + weeksPassed * week
        }
        return reset.timeIntervalSince(now) <= 10_000 * week ? reset : nil
    }

    /// The window cut at local midnights, each piece with the start of the
    /// calendar day it's named after. A piece under an hour long (a window
    /// that starts or ends just off midnight) joins its neighbour, under the
    /// neighbour's day, rather than drawing a near-empty bar.
    private static func dayBuckets(_ window: DateInterval, calendar: Calendar) -> [(bucket: DateInterval, day: Date)] {
        var buckets: [(bucket: DateInterval, day: Date)] = []
        var dayStart = calendar.startOfDay(for: window.start)
        while dayStart < window.end, buckets.count < 16 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart), next > dayStart else { break }
            buckets.append((DateInterval(start: max(dayStart, window.start), end: min(next, window.end)), dayStart))
            dayStart = next
        }
        if buckets.count > 1, buckets[0].bucket.duration < 3600 {
            let first = buckets.removeFirst()
            buckets[0].bucket = DateInterval(start: first.bucket.start, end: buckets[0].bucket.end)
        }
        if buckets.count > 1, buckets[buckets.count - 1].bucket.duration < 3600 {
            let last = buckets.removeLast()
            buckets[buckets.count - 1].bucket = DateInterval(start: buckets[buckets.count - 1].bucket.start, end: last.bucket.end)
        }
        return buckets
    }

    /// Colour slots for the priced models in a chart: each model line's
    /// newest model present gets the line's slot; any other gets the next
    /// extra slot, in price-table order. Models with no price get none.
    private static func seriesSlots(for models: [String], prices: PriceTable) -> [String: Int] {
        let priced = models.compactMap { model in prices.price(for: model).map { (model: model, price: $0) } }
        let order = Dictionary(prices.models.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var slots: [String: Int] = [:]
        var takenFamilies: Set<String> = []
        var nextExtra = CostChart.extraSeries.lowerBound
        for (model, price) in priced.sorted(by: { (order[$0.price.id] ?? .max, $0.model) < (order[$1.price.id] ?? .max, $1.model) }) {
            if let slot = CostChart.familySeries[price.family], !takenFamilies.contains(price.family) {
                takenFamilies.insert(price.family)
                slots[model] = slot
            } else {
                slots[model] = min(nextExtra, CostChart.otherSeries)
                nextExtra += 1
            }
        }
        return slots
    }

    /// Dollars and tokens for some replies. Models missing from the price
    /// table add tokens but no dollars.
    struct Total {
        var dollars: Double = 0
        var tokens: Int = 0

        init(_ entries: [UsageEntry], prices: PriceTable) {
            for entry in entries {
                dollars += prices.price(for: entry.model)?.dollars(entry) ?? 0
                tokens += entry.tokens.total
            }
        }

        /// "$412 · 756M tokens"
        var text: String { "\(UsageCost.dollarText(dollars)) · \(UsageCost.tokenText(tokens)) tokens" }
    }

    /// "$3.05" below $10, then whole dollars: "$41", "$412", "$1,234".
    static func dollarText(_ dollars: Double) -> String {
        if dollars < 9.995 {
            return "$" + String(format: "%.2f", max(dollars, 0))
        }
        return "$" + Int(dollars.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// "950", "8.2K", "820K", "2.3M", "756M", "1.2B".
    static func tokenText(_ tokens: Int) -> String {
        let value = Double(tokens)
        func scaled(_ unit: Double, _ suffix: String) -> String {
            let x = value / unit
            guard x < 9.95 else { return String(Int(x.rounded())) + suffix }
            let text = String(format: "%.1f", x)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        switch tokens {
        case ..<1_000: return String(max(tokens, 0))
        case ..<999_500: return scaled(1_000, "K")
        case ..<999_500_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }
}
