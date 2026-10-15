import Foundation

/// Everything the UI shows, computed by `UsageEngine`.
public struct UsageSnapshot: Equatable, Sendable {
    public var menuBar: MenuBarLabel
    /// One per provider, in display order.
    public var sections: [ProviderSection]
    /// Notifications to post now; usually none.
    public var alerts: [LimitAlert] = []
    /// What has been alerted, including `alerts`: the next evaluation's
    /// input, saved between launches.
    public var alertMemory = AlertMemory()
    /// What the popover says instead of sections when no provider is on;
    /// nil otherwise.
    public var emptyText: String? = nil

    /// The section of the provider with `id`, if it's shown.
    public subscript(id: String) -> ProviderSection? {
        sections.first { $0.id == id }
    }
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

/// The menu bar text: each provider's symbol and part, in display order,
/// e.g. `✳ 61% · ⌘ 13%`.
public struct MenuBarLabel: Equatable, Sendable {
    public var parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    /// One provider's symbol and part.
    public struct Part: Equatable, Sendable, Identifiable {
        /// The provider's id.
        public var id: String
        /// The provider's name, for VoiceOver.
        public var name: String
        public var symbol: String
        public var value: LabelPart

        public init(id: String, name: String, symbol: String, value: LabelPart) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.value = value
        }
    }

    public var text: String {
        parts.map { "\($0.symbol) \($0.value.text)" }.joined(separator: " · ")
    }

    /// The title in runs, left to right: symbols and separators plain, each
    /// value coloured by its level. Empty when there are no parts, where
    /// the status item shows a neutral icon instead.
    public var runs: [Run] {
        parts.enumerated().flatMap { index, part in
            [Run(text: (index == 0 ? "" : " · ") + part.symbol + " ", level: nil), Run(text: part.value.text, level: part.value.level)]
        }
    }

    /// A stretch of the title in one style.
    public struct Run: Equatable, Sendable {
        public var text: String
        /// The level to colour it by; nil for plain text.
        public var level: Level?

        public init(text: String, level: Level?) {
            self.text = text
            self.level = level
        }
    }

    /// What VoiceOver reads: "Usage. Claude 61%. Codex 13%.", or the app's
    /// name for the neutral icon, which shows both when nothing is on and
    /// when every part is hidden.
    public var accessibilityText: String {
        if parts.isEmpty { return "UsageBar" }
        return (["Usage."] + parts.map { "\($0.name) \($0.value.text)." }).joined(separator: " ")
    }

    /// The part of the provider with `id`, if it has one.
    public subscript(id: String) -> LabelPart? {
        parts.first { $0.id == id }?.value
    }
}

/// One provider's part of the menu bar text.
public struct LabelPart: Equatable, Sendable {
    public var text: String
    public var level: Level

    public init(text: String, level: Level) {
        self.text = text
        self.level = level
    }
}

/// One provider's block in the popover.
public struct ProviderSection: Equatable, Sendable, Identifiable {
    /// The provider's id.
    public var id: String
    /// The title: "Claude".
    public var name: String
    /// The provider's menu bar glyph: "✳".
    public var symbol: String
    /// The SF Symbol beside the title.
    public var systemImage: String
    /// Plan badge, e.g. "Max" or "Pro"; nil when unknown.
    public var plan: String?
    /// "Updated 3 min ago"; nil when there's no reading.
    public var updatedText: String?
    /// Top to bottom.
    public var rows: [Row]
    /// A line under the rows, e.g. "No 5-hour limit on your plan".
    public var note: String?
    /// The weekly cost chart; nil where usage isn't tracked.
    public var chart: CostChart? = nil

    /// One row of a section.
    public enum Row: Equatable, Sendable, Identifiable {
        /// A limit window's meter.
        case meter(Meter)
        /// Credit left of a total, as a meter.
        case credit(CreditMeter)
        /// A label and an amount.
        case value(ValueLine)

        public var id: String {
            switch self {
            case let .meter(meter): meter.id
            case let .credit(credit): credit.id
            case let .value(value): value.id
            }
        }
    }

    /// The limit windows' meters, top to bottom.
    public var meters: [Meter] {
        rows.compactMap { row in
            if case let .meter(meter) = row { meter } else { nil }
        }
    }
}

/// Credit left of a total: a bar filled by what's used, coloured by level.
public struct CreditMeter: Equatable, Sendable, Identifiable {
    public var id: String
    /// "Credit".
    public var label: String
    /// "$12.40 left of $20", "$12.40 left", or "—" without a reading.
    public var valueText: String
    /// Bar fill: the fraction used, 0...1.
    public var fraction: Double
    /// Warning from 90% used; maxed with nothing left.
    public var level: Level
    /// "Resets Sun 12:00 AM"; nil when the credit doesn't reset or there's
    /// no reading.
    public var resetText: String? = nil

    public init(id: String, label: String, valueText: String, fraction: Double, level: Level, resetText: String? = nil) {
        self.id = id
        self.label = label
        self.valueText = valueText
        self.fraction = fraction
        self.level = level
        self.resetText = resetText
    }
}

/// A balance or spend row: "Balance" on the left, "¥48.20" on the right.
public struct ValueLine: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// "¥48.20", or "—" without a reading.
    public var valueText: String
    /// A muted line under it, e.g. "¥100 topped up · ¥10 granted".
    public var detailText: String? = nil

    public init(id: String, label: String, valueText: String, detailText: String? = nil) {
        self.id = id
        self.label = label
        self.valueText = valueText
        self.detailText = detailText
    }
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
