import Foundation
import Testing
import UsageCore

/// The engine run as the app runs it, with the Alerts settings it's given.
private struct SettingsRun {
    var memory = AlertMemory()
    var settings = AlertSettings()

    mutating func callAsFunction(claude: ClaudeLimits? = nil, codex: CodexLimits? = nil, at time: Date = now) -> [String] {
        run(claude: claude, codex: codex, at: time).alerts.map(\.title)
    }

    mutating func run(claude: ClaudeLimits? = nil, codex: CodexLimits? = nil, at time: Date = now) -> UsageSnapshot {
        let snapshot = UsageEngine.snapshot(
            from: Readings(claude: claude, codex: codex), now: time, timeZone: losAngeles,
            alertMemory: memory, alertSettings: settings
        )
        memory = snapshot.alertMemory
        return snapshot
    }
}

private func meter(_ snapshot: UsageSnapshot, _ provider: String, _ id: String) -> Meter? {
    snapshot[provider]?.rows.lazy.compactMap { if case let .meter(meter) = $0, meter.id == id { meter } else { nil } }.first
}

@Suite("Alert threshold")
struct AlertThresholdTests {
    @Test("a 75% threshold alerts on crossing 75%, not 90%")
    func customCrossing() {
        var run = SettingsRun(settings: AlertSettings(threshold: 75))
        #expect(run(claude: claude(fiveHour: 74)) == [])
        #expect(run(claude: claude(fiveHour: 76)) == ["Claude 5-hour session at 76%"])
        #expect(run(claude: claude(fiveHour: 91)) == [])
    }

    @Test("meters and the menu bar turn to warning at the chosen threshold")
    func colours() {
        var run = SettingsRun(settings: AlertSettings(threshold: 75))
        let below = run.run(claude: claude(fiveHour: 74, weekly: 10), codex: codex(weekly: 75))
        #expect(meter(below, "claude", "claude.fiveHour")?.level == .normal)
        #expect(below.menuBar.claude.level == .normal)
        #expect(meter(below, "codex", "codex.10080m")?.level == .warning)
        #expect(below.menuBar.codex.level == .warning)

        // At the default 90%, 75% is still normal.
        var plain = SettingsRun()
        let standard = plain.run(codex: codex(weekly: 89))
        #expect(meter(standard, "codex", "codex.10080m")?.level == .normal)
        #expect(standard.menuBar.codex.level == .normal)
    }

    @Test("lowering the threshold below a window's level warns once, then nothing repeats")
    func lowering() {
        var run = SettingsRun()
        #expect(run(claude: claude(fiveHour: 82)) == [])
        run.settings.setThreshold(80)
        #expect(run(claude: claude(fiveHour: 82), at: now + 60) == ["Claude 5-hour session at 82%"])
        #expect(run(claude: claude(fiveHour: 83), at: now + 120) == [])
        run.settings.setThreshold(75)
        #expect(run(claude: claude(fiveHour: 84), at: now + 180) == [])
    }

    @Test("raising the threshold after a warning repeats nothing, even on crossing the new one")
    func raising() {
        var run = SettingsRun(settings: AlertSettings(threshold: 75))
        #expect(run(claude: claude(fiveHour: 78)) == ["Claude 5-hour session at 78%"])
        run.settings.setThreshold(95)
        #expect(run(claude: claude(fiveHour: 78), at: now + 60) == [])
        #expect(run(claude: claude(fiveHour: 96), at: now + 120) == [])
    }

    @Test("raising the threshold above a window that hasn't warned keeps it quiet until it crosses the new one")
    func raisingBeforeWarning() {
        var run = SettingsRun()
        #expect(run(claude: claude(fiveHour: 85)) == [])
        run.settings.setThreshold(95)
        #expect(run(claude: claude(fiveHour: 92), at: now + 60) == [])
        #expect(run(claude: claude(fiveHour: 95), at: now + 120) == ["Claude 5-hour session at 95%"])
    }

    @Test("only the offered thresholds are taken")
    func presets() {
        #expect(AlertSettings.thresholds == [50, 75, 80, 85, 90, 95])
        #expect(AlertSettings().threshold == 90)
        var settings = AlertSettings(threshold: 77)
        #expect(settings.threshold == 90)
        settings.setThreshold(50)
        settings.setThreshold(101)
        #expect(settings.threshold == 50)
    }
}

@Suite("Alert kinds and providers")
struct AlertKindTests {
    /// The 5-hour window at 100%, resetting at 3:45 PM.
    static let maxed = claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T15:45:00-07:00"))
    static let afterReset = date("2026-10-10T15:46:00-07:00")

    @Test("with limit reached alerts off, a window first seen maxed stays quiet but still announces its reset")
    func limitReachedOff() {
        var run = SettingsRun(settings: AlertSettings(limitReached: false))
        #expect(run(claude: Self.maxed) == [])
        #expect(run(claude: Self.maxed, at: Self.afterReset) == ["Claude 5-hour limit reset"])
        // Threshold warnings still fire.
        #expect(run(claude: claude(fiveHour: 92, fiveHourResetsAt: date("2026-10-10T20:45:00-07:00")), at: Self.afterReset) == ["Claude 5-hour session at 92%"])
    }

    @Test("with limit reset alerts off, a reset passes quietly, and turning them back on doesn't announce it late")
    func limitResetOff() {
        var run = SettingsRun(settings: AlertSettings(limitReset: false))
        #expect(run(claude: Self.maxed) == ["Claude 5-hour limit reached"])
        #expect(run(claude: Self.maxed, at: Self.afterReset) == [])
        run.settings.limitReset = true
        #expect(run(claude: Self.maxed, at: Self.afterReset + 60) == [])
    }

    @Test("a provider with alerts off still shows, but alerts nothing; the others alert as before")
    func providerOff() {
        var settings = AlertSettings()
        settings.setAlerts(false, for: "claude")
        var run = SettingsRun(settings: settings)
        let snapshot = run.run(claude: Self.maxed, codex: codex(weekly: 93))
        #expect(snapshot.alerts.map(\.title) == ["Codex weekly limit at 93%"])
        #expect(snapshot.claude.rows.count == 3)
        #expect(snapshot.menuBar.claude.level == .maxed)
        // Its reset passes quietly too.
        #expect(run(claude: Self.maxed, codex: codex(weekly: 93), at: Self.afterReset) == [])
    }

    @Test("turning a provider's alerts back on mid-cycle warns once for a window above the threshold")
    func providerBackOn() {
        var settings = AlertSettings()
        settings.setAlerts(false, for: "codex")
        var run = SettingsRun(settings: settings)
        #expect(run(codex: codex(weekly: 93)) == [])
        run.settings.setAlerts(true, for: "codex")
        #expect(run(codex: codex(weekly: 93), at: now + 60) == ["Codex weekly limit at 93%"])
        #expect(run(codex: codex(weekly: 94), at: now + 120) == [])
    }

    @Test("a saved alerts.json still loads with custom settings: nothing repeats, a pending reset is announced")
    func savedMemory() throws {
        let memory = AlertMemory.decode(try Data(contentsOf: fixtureURL("alerts-v1.json")))
        #expect(memory.cycles.count == 3)
        var run = SettingsRun(memory: memory, settings: AlertSettings(threshold: 75))
        // The file's 5-hour cycle (maxed) reset at 1791666000; its weekly and Codex cycles have warned.
        let resetsAt = Date(timeIntervalSince1970: 1_791_666_000)
        let titles = run(
            claude: claude(fiveHour: 10, weekly: 80, fable: 0, fiveHourResetsAt: resetsAt + 5 * 3600,
                           weeklyResetsAt: Date(timeIntervalSince1970: 1_791_900_000)),
            codex: codex(weekly: 80, resetsAt: Date(timeIntervalSince1970: 1_792_095_360)),
            at: resetsAt + 60
        )
        #expect(titles == ["Claude 5-hour limit reset"])
    }
}

@Suite("Alert settings persistence")
struct AlertSettingsPersistenceTests {
    private final class Defaults: KeyValueStore {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    @Test("nothing saved reads as the defaults: 90%, both kinds on, every provider alerting")
    func defaults() {
        let settings = AlertSettings(loadingFrom: Defaults(), catalog: BuiltInProviders.catalog)
        #expect(settings == AlertSettings())
        #expect(settings.threshold == 90 && settings.limitReached && settings.limitReset)
        #expect(BuiltInProviders.catalog.allSatisfy { settings.alerts(for: $0.id) })
    }

    @Test("the threshold, both kinds and per-provider switches round-trip through UserDefaults")
    func roundTrip() {
        var settings = AlertSettings(threshold: 75, limitReached: false, limitReset: false)
        settings.setAlerts(false, for: "codex")
        let store = Defaults()
        settings.save(to: store)
        #expect(store.values["alerts.threshold"] as? Int == 75)
        #expect(store.values["providers.codex.alerts"] as? Bool == false)
        let loaded = AlertSettings(loadingFrom: store, catalog: BuiltInProviders.catalog)
        #expect(loaded == settings)
        #expect(!loaded.alerts(for: "codex") && loaded.alerts(for: "claude"))
    }

    @Test("a mistyped or unoffered saved value reads as its default")
    func mistyped() {
        let store = Defaults()
        store.values = ["alerts.threshold": 42, "alerts.limitReached": "no", "providers.claude.alerts": 0]
        let loaded = AlertSettings(loadingFrom: store, catalog: BuiltInProviders.catalog)
        #expect(loaded.threshold == 90 && loaded.limitReached && loaded.alerts(for: "claude"))
    }
}

@Suite("Alerts in the Providers menu")
struct AlertMenuTests {
    @Test("each provider's row shows whether its alerts are on, on by default")
    func providerRows() {
        var alerts = AlertSettings()
        alerts.setAlerts(false, for: "codex")
        let items = ProviderSettings().menuItems(BuiltInProviders.catalog, detected: ["claude", "codex"], alerts: alerts)
        #expect(items.first { $0.id == "claude" }?.alerts == true)
        #expect(items.first { $0.id == "codex" }?.alerts == false)
        #expect(items.first { $0.id == "deepseek" }?.alerts == true)
    }
}

@Suite("Alert settings in fixtures")
struct AlertFixtureTests {
    @Test("a fixture can set the Alerts settings, and its meters and menu bar follow its threshold")
    func custom() throws {
        let fixture = try loadFixture("alerts-75")
        var expected = AlertSettings(threshold: 75, limitReset: false)
        expected.setAlerts(false, for: "codex")
        #expect(fixture.alertSettings == expected)
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone,
                                            alertSettings: fixture.alertSettings)
        #expect(snapshot.claude.meters.map(\.level) == [.normal, .warning, .normal])
        #expect(snapshot.menuBar.claude.level == .warning)
        #expect(snapshot.menuBar.codex.level == .warning)
        // Codex's alerts are off: only Claude's weekly window alerts.
        #expect(snapshot.alerts.map(\.title) == ["Claude weekly limit at 78%"])
    }

    @Test("a fixture without Alerts settings, or with unreadable ones, uses the defaults")
    func defaults() throws {
        #expect(try loadFixture("near").alertSettings == AlertSettings())
        let json = #"{"now": "2026-10-10T14:40:00-07:00", "alerts": {"threshold": "high"}, "readings": {}}"#
        #expect(try Fixture.decode(Data(json.utf8)).alertSettings == AlertSettings())
    }
}
