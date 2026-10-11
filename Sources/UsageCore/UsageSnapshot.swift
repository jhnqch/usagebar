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
    public static let familySeries = ["opus": 0, "fable": 1, "sonnet": 2, "haiku": 3]
    public static let extraSeries = 4..<8
    public static let otherSeries = 8
}
