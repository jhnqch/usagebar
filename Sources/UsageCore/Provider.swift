import Foundation

/// One AI tool or API whose usage UsageBar shows. A provider is a value that
/// holds its latest readings; the app's monitors replace them as sources
/// report, and the engine asks it, with a clock, what to show.
///
/// The engine does the rest for every provider alike: meters with pace for
/// its limit windows, alerts for those windows, its section in the popover
/// and its part of the menu bar label.
///
/// A provider decodes from a fixture's `readings` object, which all
/// providers share: it reads only its own keys, ignores the rest, and
/// decodes a missing or unreadable key as "no reading" rather than failing.
public protocol Provider: Decodable, Equatable, Sendable {
    /// Stable and unique: "claude", "codex". Its windows' ids start with it.
    var id: String { get }
    /// "Claude": the section's title and the menu bar's spoken label.
    var name: String { get }
    /// The menu bar glyph in front of its part: "✳".
    var symbol: String { get }
    /// The SF Symbol beside the section's title.
    var systemImage: String { get }

    /// What to show at `clock`'s time.
    func report(clock: Clock) -> ProviderReport

    /// The same readings moved `offset` seconds later, so a recorded sample
    /// sits relative to a new "now" as it sat relative to the old one.
    func shifted(by offset: TimeInterval) -> Self
}

extension Provider {
    /// Whether `other` is this provider with the same readings.
    func isEqual(to other: any Provider) -> Bool {
        (other as? Self) == self
    }
}

/// What a provider shows at one time, before the engine adds meters, pace,
/// alerts and the menu bar part.
public struct ProviderReport: Equatable, Sendable {
    /// Plan badge, e.g. "Max" or "Pro"; nil when unknown.
    public var plan: String?
    /// When the newest reading was taken; nil when there's no reading.
    public var updatedAt: Date?
    /// The section's rows, top to bottom.
    public var rows: [Row]
    /// A line under the rows, e.g. "No 5-hour limit on your plan".
    public var note: String?
    /// The weekly cost chart; nil where usage isn't tracked.
    public var chart: CostChart?

    public init(plan: String? = nil, updatedAt: Date? = nil, rows: [Row] = [], note: String? = nil, chart: CostChart? = nil) {
        self.plan = plan
        self.updatedAt = updatedAt
        self.rows = rows
        self.note = note
        self.chart = chart
    }

    /// One row of a provider's section.
    public enum Row: Equatable, Sendable {
        /// A limit window: a meter with pace, alerts at 90% and on reset, and
        /// a share of the menu bar part.
        case window(LimitWindow)
        /// Credit with a total: a meter of what's used, reading
        /// "$12.40 left of $20". No pace, no alerts, no menu bar part.
        case credit(CreditRow)
        /// A plain amount: "Balance ¥48.20", "This month $3.10".
        case value(ValueRow)
    }

    /// The limit windows, in row order.
    var windows: [LimitWindow] {
        rows.compactMap { row in
            if case let .window(window) = row { window } else { nil }
        }
    }
}

/// Credit or a balance with a known total, e.g. an API key's spending limit.
public struct CreditRow: Equatable, Sendable {
    /// Unique across providers, e.g. "openrouter.credit".
    public var id: String
    /// "Credit".
    public var label: String
    /// What's left; nil shows "—".
    public var left: Amount?
    /// The total it's left of; nil when there's none (the row then reads
    /// "$12.40 left" over an empty bar).
    public var total: Amount?
    /// When the credit tops up again, if it does.
    public var resetsAt: Date?

    public init(id: String, label: String, left: Amount?, of total: Amount?, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.left = left
        self.total = total
        self.resetsAt = resetsAt
    }

    func shifted(by offset: TimeInterval) -> CreditRow {
        var copy = self
        copy.resetsAt = resetsAt.map { $0 + offset }
        return copy
    }
}

/// A labelled amount: a balance, or what was spent in a period.
public struct ValueRow: Equatable, Sendable {
    /// Unique across providers, e.g. "deepseek.balance.CNY".
    public var id: String
    /// "Balance", "This month".
    public var label: String
    /// Nil shows `text`, or "—" without one.
    public var value: Amount?
    /// What shows without an amount, for a value that isn't one: "Unlimited".
    public var text: String?
    /// A muted line under it: "¥100 topped up · ¥10 granted". Shown only
    /// with a value or text.
    public var detail: String?

    public init(id: String, label: String, value: Amount?, text: String? = nil, detail: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.text = text
        self.detail = detail
    }
}

/// A named limit window, its length and its reading, if any.
public struct LimitWindow: Equatable, Sendable {
    /// Unique across providers, e.g. "claude.fiveHour". Alert memory knows
    /// windows by it, so it must stay the same from one release to the next.
    public var id: String
    /// The meter's label: "5-hour session".
    public var label: String
    /// The window's length, for pace.
    public var minutes: Int
    /// Nil shows "—".
    public var reading: LimitReading?
    /// What alerts call it when reached or reset: "Claude 5-hour limit".
    public var alertName: String
    /// What alerts call it at 90%: "Claude 5-hour session". Defaults to
    /// `alertName`.
    public var nearAlertName: String
    /// Whether it counts toward the provider's menu bar part. A limit that
    /// blocks only one model (Claude's Fable) stays out.
    public var inMenuBar: Bool
    /// What the window has used so far at API prices, e.g.
    /// "$4.12 · 1.9M tokens this session"; nil where it isn't tracked.
    public var usageText: String?
    /// The percent used when the source gave one but no reset (or one that
    /// looked wrong): the meter shows it, without a reset, pace, alerts or
    /// a menu bar share. Ignored with a `reading`.
    public var percentWithoutReset: Double?

    public init(
        id: String,
        label: String,
        minutes: Int,
        reading: LimitReading?,
        alertName: String,
        nearAlertName: String? = nil,
        inMenuBar: Bool = true,
        usageText: String? = nil,
        percentWithoutReset: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.minutes = minutes
        self.reading = reading
        self.alertName = alertName
        self.nearAlertName = nearAlertName ?? alertName
        self.inMenuBar = inMenuBar
        self.usageText = usageText
        self.percentWithoutReset = percentWithoutReset
    }
}
