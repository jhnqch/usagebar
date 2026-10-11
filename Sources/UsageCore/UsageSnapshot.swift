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
}
