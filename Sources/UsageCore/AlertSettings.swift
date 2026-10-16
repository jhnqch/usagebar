import Foundation

/// The Alerts section of the Providers menu: the warning threshold, which
/// alert kinds fire, and which providers alert. The engine's input; the app
/// keeps it in `UserDefaults`.
public struct AlertSettings: Equatable, Sendable {
    /// The thresholds the menu offers, in percent.
    public static let thresholds = [50, 75, 80, 85, 90, 95]
    /// The threshold until the user picks one.
    public static let defaultThreshold = 90

    /// The percent at which a window warns: its meter and menu bar part
    /// turn orange and it alerts once a cycle. Always one of `thresholds`.
    public private(set) var threshold: Int
    /// Whether a window first seen at 100% alerts "limit reached".
    public var limitReached: Bool
    /// Whether a maxed window that has reset alerts "limit reset".
    public var limitReset: Bool
    /// Explicit per-provider "Alerts" choices by provider id; a provider
    /// without one alerts.
    public private(set) var providers: [String: Bool]

    public init(threshold: Int = defaultThreshold, limitReached: Bool = true, limitReset: Bool = true, providers: [String: Bool] = [:]) {
        self.threshold = Self.thresholds.contains(threshold) ? threshold : Self.defaultThreshold
        self.limitReached = limitReached
        self.limitReset = limitReset
        self.providers = providers
    }

    /// Picks a threshold; one the menu doesn't offer is ignored.
    public mutating func setThreshold(_ percent: Int) {
        if Self.thresholds.contains(percent) { threshold = percent }
    }

    /// Turns a provider's alerts on or off. Off silences it without hiding it.
    public mutating func setAlerts(_ isOn: Bool, for id: String) {
        providers[id] = isOn
    }

    /// Whether the provider with `id` alerts.
    public func alerts(for id: String) -> Bool {
        providers[id] ?? true
    }

    var warningAt: Double { Double(threshold) }

    // MARK: Persistence

    static let thresholdKey = "alerts.threshold"
    static let limitReachedKey = "alerts.limitReached"
    static let limitResetKey = "alerts.limitReset"
    static func providerKey(_ id: String) -> String { "providers.\(id).alerts" }

    /// The settings saved in `store`, for the providers in `catalog`. A
    /// missing, mistyped or unoffered value reads as the default.
    public init(loadingFrom store: some KeyValueStore, catalog: [ProviderInfo]) {
        self.init(
            threshold: (store.object(forKey: Self.thresholdKey) as? Int) ?? Self.defaultThreshold,
            limitReached: (store.object(forKey: Self.limitReachedKey) as? Bool) ?? true,
            limitReset: (store.object(forKey: Self.limitResetKey) as? Bool) ?? true,
            providers: catalog.reduce(into: [:]) { providers, info in
                providers[info.id] = store.object(forKey: Self.providerKey(info.id)) as? Bool
            }
        )
    }

    /// Saves the settings to `store`.
    public func save(to store: some KeyValueStore) {
        store.set(threshold, forKey: Self.thresholdKey)
        store.set(limitReached, forKey: Self.limitReachedKey)
        store.set(limitReset, forKey: Self.limitResetKey)
        for (id, isOn) in providers {
            store.set(isOn, forKey: Self.providerKey(id))
        }
    }
}
