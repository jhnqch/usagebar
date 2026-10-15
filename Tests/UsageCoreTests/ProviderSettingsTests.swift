import Foundation
import Testing
import UsageCore

/// A file system that holds only the paths it's given.
private struct FakeFileSystem: FileSystem {
    var paths: Set<String> = []

    func fileExists(atPath path: String) -> Bool {
        paths.contains(path)
    }
}

private let home = "/Users/test"

@Suite("Provider detection")
struct ProviderDetectionTests {
    private func detected(_ paths: Set<String>, environment: [String: String] = [:]) -> Set<String> {
        ProviderDetection.detected(
            BuiltInProviders.catalog, fileSystem: FakeFileSystem(paths: paths), home: home, environment: environment
        )
    }

    @Test("nothing installed detects nothing")
    func nothing() {
        #expect(detected([]) == [])
    }

    @Test("~/.claude detects Claude, ~/.codex detects Codex")
    func configDirectories() {
        #expect(detected(["/Users/test/.claude"]) == ["claude"])
        #expect(detected(["/Users/test/.codex"]) == ["codex"])
        #expect(detected(["/Users/test/.claude", "/Users/test/.codex"]) == ["claude", "codex"])
    }

    @Test("a Claude Code install without ~/.claude detects Claude")
    func claudeCodeInstall() {
        #expect(detected(["/Users/test/.local/bin/claude"]) == ["claude"])
        #expect(detected(["/opt/homebrew/bin/claude"]) == ["claude"])
        #expect(detected(["/usr/local/bin/claude"]) == ["claude"])
    }

    @Test("ChatGPT's bundled codex or an installed codex detects Codex")
    func codexBinary() {
        #expect(detected(["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]) == ["codex"])
        #expect(detected(["/opt/homebrew/bin/codex"]) == ["codex"])
    }

    @Test("CLAUDE_CONFIG_DIR and CODEX_HOME stand in for the default directories")
    func environmentOverrides() {
        let environment = ["CLAUDE_CONFIG_DIR": "/elsewhere/claude", "CODEX_HOME": "/elsewhere/codex"]
        #expect(detected(["/elsewhere/claude", "/elsewhere/codex"], environment: environment) == ["claude", "codex"])
    }
}

/// UserDefaults' role, held in memory.
private final class FakeDefaults: KeyValueStore {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// A provider with no limit windows by default in the menu bar, as a key
/// provider will be.
private let keyInfo = ProviderInfo(id: "key", name: "Key")
private let catalog = BuiltInProviders.catalog + [keyInfo]

@Suite("Provider settings")
struct ProviderSettingsTests {
    @Test("by default the detected providers are on and in the menu bar")
    func defaults() {
        let selection = ProviderSettings().selection(catalog, detected: ["claude", "codex"])
        #expect(selection.enabled == ["claude", "codex"])
        #expect(selection.menuBar == ["claude", "codex"])
    }

    @Test("an undetected provider is off")
    func undetected() {
        let selection = ProviderSettings().selection(catalog, detected: ["codex"])
        #expect(selection.enabled == ["codex"])
        #expect(selection.menuBar == ["codex"])
    }

    @Test("a provider the user turns off stays off while detected; one turned on shows while undetected")
    func explicitChoice() {
        var settings = ProviderSettings()
        settings.setEnabled(false, for: "claude")
        settings.setEnabled(true, for: "key")
        let selection = settings.selection(catalog, detected: ["claude", "codex"])
        #expect(selection.enabled == ["codex", "key"])
        #expect(!selection.menuBar.contains("claude"))
    }

    @Test("show in menu bar can be turned off and on per provider")
    func menuBarChoice() {
        var settings = ProviderSettings()
        settings.setInMenuBar(false, for: "claude")
        settings.setInMenuBar(true, for: "key")
        settings.setEnabled(true, for: "key")
        #expect(settings.selection(catalog, detected: ["claude", "codex"]).menuBar == ["codex", "key"])
    }

    @Test("with no Claude or Codex, the first provider on shows in the menu bar")
    func menuBarFallback() {
        var settings = ProviderSettings()
        settings.setEnabled(true, for: "key")
        #expect(settings.selection(catalog, detected: []).menuBar == ["key"])
    }

    @Test("turning every menu bar part off is respected")
    func menuBarAllOff() {
        var settings = ProviderSettings()
        settings.setInMenuBar(false, for: "codex")
        #expect(settings.selection(catalog, detected: ["codex"]).menuBar == [])
    }

    @Test("settings survive a relaunch through the defaults")
    func persistence() {
        let defaults = FakeDefaults()
        var settings = ProviderSettings()
        settings.setEnabled(false, for: "claude")
        settings.setInMenuBar(false, for: "codex")
        settings.save(to: defaults)
        #expect(ProviderSettings(loadingFrom: defaults, catalog: catalog) == settings)
    }

    @Test("empty or mistyped defaults read as no choice")
    func badDefaults() {
        let defaults = FakeDefaults()
        defaults.values = ["providers.claude.enabled": "yes", "providers.codex.inMenuBar": 3]
        #expect(ProviderSettings(loadingFrom: defaults, catalog: catalog) == ProviderSettings())
        #expect(ProviderSettings(loadingFrom: FakeDefaults(), catalog: catalog) == ProviderSettings())
    }

    @Test("the Providers menu lists every provider with its toggles")
    func menuItems() {
        var settings = ProviderSettings()
        settings.setInMenuBar(false, for: "codex")
        let items = settings.menuItems(catalog, detected: ["claude", "codex"])
        #expect(items.map(\.id) == ["claude", "codex", "key"])
        #expect(items.map(\.isOn) == [true, true, false])
        #expect(items.map(\.inMenuBar) == [true, false, false])
        #expect(items.map(\.detail) == [nil, nil, "Not found on this Mac"])
    }
}

@Suite("Provider selection in the snapshot")
struct ProviderSelectionSnapshotTests {
    private let readings = Readings([
        ClaudeProvider(statusLine: claude(fiveHour: 42, weekly: 61)),
        CodexProvider(appServer: codex(weekly: 13)),
    ])

    private func snapshot(_ selection: ProviderSelection, readings: Readings? = nil, memory: AlertMemory = AlertMemory()) -> UsageSnapshot {
        UsageEngine.snapshot(from: readings ?? self.readings, now: now, timeZone: losAngeles, alertMemory: memory, selection: selection)
    }

    @Test("a provider that's off has no section and no menu bar part")
    func offProvider() {
        let snapshot = snapshot(ProviderSelection(enabled: ["codex"], menuBar: ["codex"]))
        #expect(snapshot.sections.map(\.id) == ["codex"])
        #expect(snapshot.menuBar.text == "⌘ 13%")
    }

    @Test("a provider on but not in the menu bar keeps its section and loses its part")
    func notInMenuBar() {
        let snapshot = snapshot(ProviderSelection(enabled: ["claude", "codex"], menuBar: ["codex"]))
        #expect(snapshot.sections.map(\.id) == ["claude", "codex"])
        #expect(snapshot.menuBar.text == "⌘ 13%")
    }

    @Test("sections follow the readings' display order, whatever the selection's order")
    func order() {
        let snapshot = snapshot(ProviderSelection(enabled: ["codex", "claude"], menuBar: ["codex", "claude"]))
        #expect(snapshot.sections.map(\.id) == ["claude", "codex"])
        #expect(snapshot.menuBar.text == "✳ 61% · ⌘ 13%")
    }

    @Test("with nothing on, the label is empty and the popover says how to add a provider")
    func nothingOn() {
        let snapshot = snapshot(ProviderSelection(enabled: [], menuBar: []))
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.menuBar.parts.isEmpty)
        #expect(snapshot.menuBar.accessibilityText == "Usage. No providers on.")
        #expect(snapshot.emptyText == """
            No providers are on. UsageBar shows Claude once Claude Code is set up (~/.claude) \
            and Codex once Codex or the ChatGPT app is installed (~/.codex). \
            Turn one on under Providers.
            """)
    }

    @Test("with a provider on, there's no empty text")
    func notEmpty() {
        #expect(snapshot(ProviderSelection(enabled: ["codex"], menuBar: [])).emptyText == nil)
    }

    @Test("a provider that's off doesn't alert, and its alert memory is kept for when it's back on")
    func offProviderAlerts() {
        let near = Readings([ClaudeProvider(statusLine: claude(fiveHour: 95)), CodexProvider(appServer: codex(weekly: 95))])
        let off = snapshot(ProviderSelection(enabled: ["codex"], menuBar: ["codex"]), readings: near)
        #expect(off.alerts.map(\.title) == ["Codex weekly limit at 95%"])

        // Claude's 5-hour window maxes out, then Claude is turned off and
        // the window resets (4:58 PM) while it's off: no reset alert, and
        // the cycle is kept so turning Claude back on doesn't repeat any.
        let both = ProviderSelection(enabled: ["claude", "codex"], menuBar: ["claude", "codex"])
        let maxed = snapshot(both, readings: Readings([ClaudeProvider(statusLine: claude(fiveHour: 100)), CodexProvider()]))
        #expect(maxed.alerts.map(\.title) == ["Claude 5-hour limit reached"])
        let afterReset = UsageEngine.snapshot(
            from: Readings([ClaudeProvider(statusLine: claude(fiveHour: 100)), CodexProvider()]),
            now: date("2026-10-10T17:30:00-07:00"), timeZone: losAngeles, alertMemory: maxed.alertMemory,
            selection: ProviderSelection(enabled: ["codex"], menuBar: [])
        )
        #expect(afterReset.alerts.isEmpty)
        #expect(afterReset.alertMemory.cycles.map(\.window) == ["claude.fiveHour"])
        #expect(afterReset.alertMemory.cycles.first?.resetAnnounced == false)
    }
}
