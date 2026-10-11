import Foundation

/// Everything the UI shows, computed by `UsageEngine`.
public struct UsageSnapshot: Equatable, Sendable {
    public var menuBar: MenuBarLabel
    public var claude: ServiceSection
    public var codex: ServiceSection
}

/// How close a limit is: normal below 90%, warning from 90%, maxed at 100%.
public enum Level: Equatable, Sendable {
    case normal, warning, maxed

    init(percent: Double) {
        switch percent {
        case 100...: self = .maxed
        case 90...: self = .warning
        default: self = .normal
        }
    }
}

/// The menu bar text: `✳ <claude> · ⌘ <codex>`.
public struct MenuBarLabel: Equatable, Sendable {
    public var claude: LabelPart
    public var codex: LabelPart

    public var text: String { "✳ \(claude.text) · ⌘ \(codex.text)" }
}

/// One service's part of the menu bar text.
public struct LabelPart: Equatable, Sendable {
    public var text: String
    public var level: Level
}

/// One service's block in the popover.
public struct ServiceSection: Equatable, Sendable {
    /// Plan badge, e.g. "Max" or "Pro"; nil when unknown.
    public var plan: String?
    /// "Updated 3 min ago"; nil when there's no reading.
    public var updatedText: String?
    public var meters: [Meter]
    /// A line under the meters, e.g. "No 5-hour limit on your plan".
    public var note: String?
    /// The weekly cost chart; nil where usage isn't tracked.
    public var chart: CostChart? = nil
}

/// One limit window's meter.
public struct Meter: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// "42%", or "—" when there's no reading.
    public var percentText: String
    /// Bar fill, 0...1.
    public var fraction: Double
    public var level: Level
    /// "Resets in 2h 18m (4:58 PM)"; nil when there's no reading.
    public var resetText: String?
    /// What the window has used so far at API prices, e.g.
    /// "$4.12 · 1.9M tokens this session"; nil where it isn't tracked.
    public var usageText: String? = nil
    /// Where the pace tick sits: the fraction of the window that has
    /// elapsed, 0...1. Nil without a reading, or once the reset has passed
    /// (the next window's start isn't known yet).
    public var elapsed: Double? = nil
    /// The tick's VoiceOver label: "54% of window elapsed".
    public var elapsedText: String? = nil
    /// The line under the meter saying where the pace leads; nil without a
    /// reading, in a window's first 10%, or once its reset has passed.
    public var prediction: PacePrediction? = nil
}

/// Where a window's pace leads: "Ahead of pace: limit around Sun 5 PM",
/// "Below pace: about 78% by reset" or "Limit reached".
public struct PacePrediction: Equatable, Sendable {
    public var text: String
    /// On course to hit the limit before the reset: drawn as a warning.
    public var isAhead: Bool

    public init(text: String, isAhead: Bool) {
        self.text = text
        self.isAhead = isAhead
    }
}

/// One bar per local calendar day of the weekly window, stacked by model in
/// API-equivalent dollars.
public struct CostChart: Equatable, Sendable {
    /// "This week", or "Last 7 days" without a weekly reading.
    public var title: String
    /// "Tue 7 AM to Tue 7 AM · 2d 16h left", or why there's no window.
    public var rangeText: String
    /// The window's dollars and tokens: "$412 · 756M tokens".
    public var totalText: String
    public var days: [Day]
    /// One row per model with usage in the window, in stacking order; models
    /// with no price last.
    public var legend: [LegendRow]

    /// The tallest bar's dollars, which the bars scale to.
    public var maxDollars: Double { days.map(\.dollars).max() ?? 0 }

    public struct Day: Equatable, Sendable, Identifiable {
        /// When the day's part of the window starts.
        public var id: Date
        /// "Tue", or "Today".
        public var label: String
        public var isToday: Bool
        /// A day still to come, drawn as an empty slot.
        public var isFuture: Bool
        /// Bottom to top, in legend order; only models with a price.
        public var segments: [Segment]
        public var dollars: Double
        /// "Wed Oct 7 · $3.50 · 100K tokens", or "Mon Oct 12 · to come".
        public var detailText: String

        public init(id: Date, label: String, isToday: Bool, isFuture: Bool, segments: [Segment], dollars: Double, detailText: String) {
            self.id = id
            self.label = label
            self.isToday = isToday
            self.isFuture = isFuture
            self.segments = segments
            self.dollars = dollars
            self.detailText = detailText
        }

        /// How to draw the day's bar: its segments' heights, bottom to top,
        /// and the gap between them. The bar's height is proportional to
        /// the day's dollars against the tallest day's, and at least 2. The
        /// gaps come out of that height, and shrink on a short bar so they
        /// take at most a third of it.
        public func stack(barHeight: Double, maxDollars: Double, gap: Double) -> (heights: [Double], gap: Double) {
            guard dollars > 0, maxDollars > 0, !segments.isEmpty else { return ([], 0) }
            let total = max(barHeight * dollars / maxDollars, 2)
            let gaps = Double(segments.count - 1)
            let gap = gaps > 0 ? min(gap, total / 3 / gaps) : 0
            let room = total - gap * gaps
            return (segments.map { room * $0.dollars / dollars }, gap)
        }
    }

    public struct Segment: Equatable, Sendable {
        public var model: String
        /// The model's colour slot.
        public var series: Int
        public var dollars: Double

        public init(model: String, series: Int, dollars: Double) {
            self.model = model
            self.series = series
            self.dollars = dollars
        }
    }

    public struct LegendRow: Equatable, Sendable, Identifiable {
        public var id: String { model }
        public var model: String
        /// "Opus 5.5", or the logged id for a model with no price.
        public var name: String
        /// "$312 · 640M tokens", or "no price · 12M tokens".
        public var valueText: String
        /// The model's colour slot; nil for a model with no price, which
        /// has no bar.
        public var series: Int?

        public init(model: String, name: String, valueText: String, series: Int?) {
            self.model = model
            self.name = name
            self.valueText = valueText
            self.series = series
        }
    }

    /// Colour slots: one per model line, in this order, then one per extra
    /// model (another version of a line, say), then a shared last slot.
    /// Codex's lines share the slots by rank: Astra like Opus, Sol like
    /// Sonnet, Luna like Haiku.
    public static let familySeries = [
        "opus": 0, "fable": 1, "sonnet": 2, "haiku": 3,
        "astra": 0, "terra": 1, "sol": 2, "luna": 3,
    ]
    public static let extraSeries = 4..<8
    public static let otherSeries = 8
}
