import Foundation
import Testing
import UsageCore

private struct NoFiles: FileSystem {
    func fileExists(atPath path: String) -> Bool { false }
}

/// UserDefaults' role, held in memory.
private final class Defaults: KeyValueStore {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// How a key provider is detected and listed in the Providers menu.
@Suite("Key provider settings")
struct KeySettingsTests {
    // Claude and Codex, not the shipped catalog, so adding a key provider leaves these alone.
    let catalog = [ClaudeProvider.info, CodexProvider.info, TestKeyAPI.info]

    func detected(_ store: MemoryKeyStore) -> Set<String> {
        ProviderDetection.detected(catalog, fileSystem: NoFiles(), home: "/Users/test", environment: [:], keys: store)
    }

    @Test("a key provider is detected once its key is saved, and gone once it's removed")
    func detection() throws {
        let store = MemoryKeyStore()
        #expect(detected(store).isEmpty)
        try store.save(fakeKey, for: TestKeyAPI.id)
        #expect(detected(store) == ["testkey"])
        try store.removeKey(for: TestKeyAPI.id)
        #expect(detected(store).isEmpty)
    }

    @Test("detection asks only whether a key is saved, never for the key itself")
    func detectionDoesNotRead() throws {
        let store = MemoryKeyStore(["testkey": fakeKey])
        _ = detected(store)
        #expect(store.reads == 0)
    }

    @Test("the menu offers a key item for key providers only, saying whether one is saved")
    func menuItems() {
        let settings = ProviderSettings()
        let missing = settings.menuItems(catalog, detected: ["claude"])
        #expect(missing.map(\.key) == [nil, nil, .missing])
        #expect(missing.last?.detail == "No API key saved")
        #expect(missing.last?.isOn == false)

        let saved = settings.menuItems(catalog, detected: ["claude", "testkey"])
        #expect(saved.last?.key == .saved)
        #expect(saved.last?.detail == nil)
        #expect(saved.last?.isOn == true)
        // Off the menu bar by default: Claude keeps its part.
        #expect(settings.selection(catalog, detected: ["claude", "testkey"]).menuBar == ["claude"])
    }

    @Test("saving settings for a provider with a key writes no key to the defaults")
    func noKeyInDefaults() throws {
        let store = MemoryKeyStore()
        try store.save(fakeKey, for: TestKeyAPI.id)
        var settings = ProviderSettings(loadingFrom: Defaults(), catalog: catalog)
        settings.setEnabled(true, for: TestKeyAPI.id)
        settings.setInMenuBar(true, for: TestKeyAPI.id)
        let defaults = Defaults()
        settings.save(to: defaults)
        _ = settings.menuItems(catalog, detected: detected(store))
        #expect(!defaults.values.isEmpty)
        #expect(!"\(defaults.values)".contains(fakeKey))
    }

    @Test("a provider's option is off until turned on, and the choice is saved and read back")
    func options() {
        let option = KeyOption(id: "extra", title: "Extra meter", detail: "Uses an undocumented endpoint")
        let info = ProviderInfo(id: "optioned", name: "Optioned", usesKey: true, options: [option])
        let catalog = catalog + [info]
        var settings = ProviderSettings()
        #expect(settings.enabledOptions(for: "optioned").isEmpty)
        #expect(settings.menuItems(catalog, detected: ["optioned"]).last?.options
            == [ProviderMenuItem.Option(id: "extra", title: "Extra meter", detail: "Uses an undocumented endpoint", isOn: false)])
        #expect(settings.menuItems(catalog, detected: ["optioned"]).first?.options == [])

        settings.setOption(true, "extra", for: "optioned")
        #expect(settings.enabledOptions(for: "optioned") == ["extra"])
        #expect(settings.menuItems(catalog, detected: ["optioned"]).last?.options.map(\.isOn) == [true])

        let defaults = Defaults()
        settings.save(to: defaults)
        #expect(defaults.values["providers.optioned.options.extra"] as? Bool == true)
        let loaded = ProviderSettings(loadingFrom: defaults, catalog: catalog)
        #expect(loaded == settings)
        #expect(loaded.enabledOptions(for: "optioned") == ["extra"])

        settings.setOption(false, "extra", for: "optioned")
        settings.save(to: defaults)
        #expect(ProviderSettings(loadingFrom: defaults, catalog: catalog).enabledOptions(for: "optioned").isEmpty)
    }
}
