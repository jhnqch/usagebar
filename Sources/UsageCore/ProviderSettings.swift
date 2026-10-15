import Foundation

/// What the app knows about a provider before it has any readings: what the
/// Providers menu lists, how to tell whether it's installed, and whether it
/// shows in the menu bar by default.
public struct ProviderInfo: Sendable {
    /// The provider's `id`.
    public var id: String
    /// The provider's `name`.
    public var name: String
    /// Whether its part shows in the menu bar until the user chooses.
    public var inMenuBarByDefault: Bool
    /// Whether it reads an API key the user pastes in: then it's detected
    /// once a key is saved, and the Providers menu offers a key window.
    public var usesKey: Bool
    /// Whether its rows are limit windows, which a menu bar part shows.
    public var hasWindows: Bool
    /// Files or directories any one of which means the provider is set up
    /// on this Mac, given the home directory and the environment.
    public var detectionPaths: @Sendable (_ home: String, _ environment: [String: String]) -> [String]

    public init(
        id: String,
        name: String,
        inMenuBarByDefault: Bool = false,
        usesKey: Bool = false,
        hasWindows: Bool = false,
        detectionPaths: @escaping @Sendable (_ home: String, _ environment: [String: String]) -> [String] = { _, _ in [] }
    ) {
        self.id = id
        self.name = name
        self.inMenuBarByDefault = inMenuBarByDefault
        self.usesKey = usesKey
        self.hasWindows = hasWindows
        self.detectionPaths = detectionPaths
    }
}

/// Whether a path exists. The app passes the real file system; tests pass a
/// fake one.
public protocol FileSystem {
    func fileExists(atPath path: String) -> Bool
}

extension FileManager: FileSystem {}

/// Which providers are set up on this Mac, from files and binaries only.
/// Detection never reads a Keychain item: reading Claude Code's shows a
/// macOS prompt, and it belongs to a provider that may stay off.
public enum ProviderDetection {
    /// The ids of the providers in `catalog` with any detection path present.
    /// A key provider is detected when `keys` has its key saved; detection
    /// only asks whether there is one, which shows no Keychain prompt.
    public static func detected(
        _ catalog: [ProviderInfo], fileSystem: some FileSystem, home: String, environment: [String: String],
        keys: (any KeyStore)? = nil
    ) -> Set<String> {
        Set(catalog.filter { info in
            if info.usesKey, keys?.hasKey(for: info.id) == true { return true }
            return info.detectionPaths(home, environment).contains { fileSystem.fileExists(atPath: $0) }
        }.map(\.id))
    }
}

/// `$name` when it's set and not empty.
func environmentPath(_ name: String, _ environment: [String: String]) -> String? {
    environment[name].flatMap { $0.isEmpty ? nil : $0 }
}

/// The user's choices in the Providers menu. A provider without a choice
/// follows the defaults: on when detected, in the menu bar when its info
/// says so.
public struct ProviderSettings: Equatable, Sendable {
    /// Explicit on/off choices by provider id.
    public private(set) var enabled: [String: Bool] = [:]
    /// Explicit "Show in menu bar" choices by provider id.
    public private(set) var inMenuBar: [String: Bool] = [:]

    public init() {}

    public mutating func setEnabled(_ isOn: Bool, for id: String) {
        enabled[id] = isOn
    }

    public mutating func setInMenuBar(_ isOn: Bool, for id: String) {
        inMenuBar[id] = isOn
    }

    /// Which providers are on, in `catalog` order, and which of those show
    /// in the menu bar.
    ///
    /// A provider is on when the user turned it on, or when it's detected
    /// and the user hasn't turned it off. One shows in the menu bar by the
    /// user's choice, else by its default; when no provider that's on has
    /// either, the first one on with limit windows shows (else the first
    /// one on), so the menu bar isn't left blank by default.
    public func selection(_ catalog: [ProviderInfo], detected: Set<String>) -> ProviderSelection {
        let on = catalog.filter { enabled[$0.id] ?? detected.contains($0.id) }
        var menuBar = Set(on.filter { inMenuBar[$0.id] ?? $0.inMenuBarByDefault }.map(\.id))
        if menuBar.isEmpty, on.allSatisfy({ inMenuBar[$0.id] == nil }), let first = on.first(where: \.hasWindows) ?? on.first {
            menuBar = [first.id]
        }
        return ProviderSelection(enabled: on.map(\.id), menuBar: menuBar)
    }

    /// The Providers menu's rows, one per provider in `catalog` order.
    public func menuItems(_ catalog: [ProviderInfo], detected: Set<String>) -> [ProviderMenuItem] {
        let selection = selection(catalog, detected: detected)
        return catalog.map { info in
            ProviderMenuItem(
                id: info.id,
                name: info.name,
                isOn: selection.enabled.contains(info.id),
                inMenuBar: selection.menuBar.contains(info.id),
                detail: detected.contains(info.id) ? nil : info.usesKey ? "No API key saved" : "Not found on this Mac",
                key: info.usesKey ? (detected.contains(info.id) ? .saved : .missing) : nil
            )
        }
    }

    // MARK: Persistence

    private static func enabledKey(_ id: String) -> String { "providers.\(id).enabled" }
    private static func inMenuBarKey(_ id: String) -> String { "providers.\(id).inMenuBar" }

    /// The choices saved in `store` for the providers in `catalog`. A
    /// missing or mistyped value reads as no choice.
    public init(loadingFrom store: some KeyValueStore, catalog: [ProviderInfo]) {
        for info in catalog {
            enabled[info.id] = store.object(forKey: Self.enabledKey(info.id)) as? Bool
            inMenuBar[info.id] = store.object(forKey: Self.inMenuBarKey(info.id)) as? Bool
        }
    }

    /// Saves every explicit choice to `store`.
    public func save(to store: some KeyValueStore) {
        for (id, isOn) in enabled {
            store.set(isOn, forKey: Self.enabledKey(id))
        }
        for (id, isOn) in inMenuBar {
            store.set(isOn, forKey: Self.inMenuBarKey(id))
        }
    }
}

/// Which providers are on, and which show in the menu bar.
public struct ProviderSelection: Equatable, Sendable {
    /// Provider ids in display order.
    public var enabled: [String]
    /// The ids of the providers on whose part shows in the menu bar.
    public var menuBar: Set<String>

    public init(enabled: [String], menuBar: Set<String>) {
        self.enabled = enabled
        self.menuBar = menuBar
    }
}

/// One provider's row in the Providers menu.
public struct ProviderMenuItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isOn: Bool
    /// Whether its part shows in the menu bar; false while it's off.
    public var inMenuBar: Bool
    /// A hint under the name, e.g. "Not found on this Mac"; nil when there's
    /// nothing to add.
    public var detail: String?
    /// For a key provider, whether its key is saved; nil for the others.
    public var key: KeyStatus? = nil

    public enum KeyStatus: Equatable, Sendable {
        case saved, missing
    }
}

/// Where settings are saved: `UserDefaults` in the app, a dictionary in
/// tests.
public protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}
