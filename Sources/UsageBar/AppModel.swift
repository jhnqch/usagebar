import Foundation
import Observation
import UsageCore

/// Holds the readings and the current snapshot. Lives on the main actor so
/// every UI state change happens there.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot
    @ObservationIgnored var onChange: ((UsageSnapshot) -> Void)?
    /// The alert memory changed: save it before the alerts are posted, so a
    /// relaunch never repeats them.
    @ObservationIgnored var onAlertMemoryChange: ((AlertMemory) -> Void)?
    /// Alerts to post.
    @ObservationIgnored var onAlerts: (([LimitAlert]) -> Void)?
    /// Which providers are on changed: start or stop their monitors.
    @ObservationIgnored var onSelectionChange: ((ProviderSelection) -> Void)?
    /// A provider's options changed: (provider id, the ids of those on).
    @ObservationIgnored var onOptionsChange: ((String, Set<String>) -> Void)?
    /// The Providers menu's rows.
    private(set) var providerItems: [ProviderMenuItem] = []
    private(set) var selection: ProviderSelection
    /// The Providers menu's Alerts settings.
    private(set) var alertSettings: AlertSettings
    @ObservationIgnored private var readings: Readings
    @ObservationIgnored private var alertMemory: AlertMemory
    @ObservationIgnored private var settings: ProviderSettings
    @ObservationIgnored private var detected: Set<String>
    @ObservationIgnored let environment: ProviderEnvironment
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Alerts wait for the first `refresh()`, once something can post them.
    init(readings: Readings, alertMemory: AlertMemory = AlertMemory(), environment: ProviderEnvironment = .live) {
        self.readings = readings
        self.alertMemory = alertMemory
        self.environment = environment
        let settings = ProviderSettings(loadingFrom: environment.defaults, catalog: BuiltInProviders.catalog)
        let detected = environment.detect()
        let selection = settings.selection(BuiltInProviders.catalog, detected: detected)
        let alertSettings = AlertSettings(loadingFrom: environment.defaults, catalog: BuiltInProviders.catalog)
        self.settings = settings
        self.detected = detected
        self.selection = selection
        self.alertSettings = alertSettings
        snapshot = UsageEngine.snapshot(from: readings, now: Date(), timeZone: .current, alertMemory: alertMemory,
                                        selection: selection, alertSettings: alertSettings)
        providerItems = settings.menuItems(BuiltInProviders.catalog, detected: detected, alerts: alertSettings)
    }

    /// Picks the warning threshold from the Providers menu's Alerts section.
    func setAlertThreshold(_ percent: Int) {
        alertSettings.setThreshold(percent)
        alertSettingsChanged()
    }

    /// Turns "limit reached" alerts on or off.
    func setLimitReachedAlerts(_ isOn: Bool) {
        alertSettings.limitReached = isOn
        alertSettingsChanged()
    }

    /// Turns "limit reset" alerts on or off.
    func setLimitResetAlerts(_ isOn: Bool) {
        alertSettings.limitReset = isOn
        alertSettingsChanged()
    }

    /// Turns a provider's alerts on or off; it stays shown either way.
    func setAlerts(_ isOn: Bool, for id: String) {
        alertSettings.setAlerts(isOn, for: id)
        alertSettingsChanged()
    }

    private func alertSettingsChanged() {
        alertSettings.save(to: environment.defaults)
        providerItems = settings.menuItems(BuiltInProviders.catalog, detected: detected, alerts: alertSettings)
        refresh()
    }

    /// Turns a provider on or off from the Providers menu.
    func setEnabled(_ isOn: Bool, for id: String) {
        settings.setEnabled(isOn, for: id)
        settingsChanged()
    }

    /// Shows or hides a provider's menu bar part from the Providers menu.
    func setInMenuBar(_ isOn: Bool, for id: String) {
        settings.setInMenuBar(isOn, for: id)
        settingsChanged()
    }

    /// Turns a provider's option on or off from the Providers menu.
    func setOption(_ isOn: Bool, _ option: String, for id: String) {
        settings.setOption(isOn, option, for: id)
        settingsChanged()
        onOptionsChange?(id, settings.enabledOptions(for: id))
    }

    /// The ids of a provider's options that are on.
    func enabledOptions(for id: String) -> Set<String> {
        settings.enabledOptions(for: id)
    }

    /// Looks for newly installed or removed providers, e.g. when the
    /// popover opens.
    func detectProviders() {
        let found = environment.detect()
        guard found != detected else { return }
        detected = found
        settingsChanged(save: false)
    }

    private func settingsChanged(save: Bool = true) {
        if save {
            settings.save(to: environment.defaults)
        }
        providerItems = settings.menuItems(BuiltInProviders.catalog, detected: detected, alerts: alertSettings)
        let updated = settings.selection(BuiltInProviders.catalog, detected: detected)
        guard updated != selection else { return }
        selection = updated
        onSelectionChange?(selection)
        refresh()
    }

    /// Changes the readings of the provider of type `P` and, if they
    /// changed, recomputes the snapshot.
    func update<P: Provider>(_ type: P.Type, _ change: (inout P) -> Void) {
        var updated = readings
        updated.update(type, change)
        guard updated != readings else { return }
        readings = updated
        refresh()
    }

    /// Recomputes the snapshot against the current clock, and posts any alerts.
    func refresh() {
        snapshot = UsageEngine.snapshot(from: readings, now: Date(), timeZone: .current, alertMemory: alertMemory,
                                        selection: selection, alertSettings: alertSettings)
        if snapshot.alertMemory != alertMemory {
            alertMemory = snapshot.alertMemory
            onAlertMemoryChange?(alertMemory)
        }
        if !snapshot.alerts.isEmpty {
            onAlerts?(snapshot.alerts)
        }
        onChange?(snapshot)
    }

    /// Keeps countdowns and "Updated N min ago" current, and notices resets.
    func startTicking(every interval: Duration = .seconds(30)) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.refresh()
            }
        }
    }
}

/// Where provider detection and settings come from: the real file system
/// and `UserDefaults` in the app.
struct ProviderEnvironment {
    var defaults: any KeyValueStore
    /// API keys: UsageBar's own Keychain items.
    var keys: any KeyStore
    var detect: () -> Set<String>

    static var live: ProviderEnvironment {
        let keys = KeychainKeyStore()
        return ProviderEnvironment(defaults: UserDefaults.standard, keys: keys) {
            ProviderDetection.detected(
                BuiltInProviders.catalog,
                fileSystem: FileManager.default,
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                environment: ProcessInfo.processInfo.environment,
                keys: keys
            )
        }
    }
}

/// The providers the app starts with, in display order, all empty: every
/// reading is live. Claude's plan badge comes from Claude Code's saved login
/// (`ClaudeUsageMonitor`).
enum SampleReadings {
    static func load() -> Readings {
        Readings([ClaudeProvider(), CodexProvider()] + BuiltInProviders.keyAPIs.map { $0.emptyProvider })
    }
}
