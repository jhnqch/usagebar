import AppKit
import UsageCore

/// The Providers menu, popped up from the popover's footer: a section per
/// provider with "Show <name>", "Show in menu bar" and "Alerts", and for a
/// key provider "API key…", which opens its key window, and its options
/// (GitHub Copilot's premium requests meter); then an Alerts section with
/// the warning threshold and the two alert kinds; then an Updates section
/// with "Check for updates automatically", "Install updates automatically"
/// and "Check now".
/// `ProviderSettings.menuItems` and `AlertSettings` decide the rows; this
/// only builds the menu and forwards the clicks.
@MainActor
enum ProvidersMenu {
    struct Actions {
        var setEnabled: (Bool, String) -> Void
        var setInMenuBar: (Bool, String) -> Void
        /// Opens the key window of the provider with this id.
        var editKey: (String) -> Void = { _ in }
        /// Turns an option (its id) of a provider (its id) on or off.
        var setOption: (Bool, String, String) -> Void = { _, _, _ in }
        /// Turns a provider's (its id) alerts on or off.
        var setAlerts: (Bool, String) -> Void = { _, _ in }
        /// Picks the warning threshold, in percent.
        var setThreshold: (Int) -> Void = { _ in }
        var setLimitReached: (Bool) -> Void = { _ in }
        var setLimitReset: (Bool) -> Void = { _ in }
        var setCheckForUpdates: (Bool) -> Void = { _ in }
        var setInstallUpdates: (Bool) -> Void = { _ in }
        var checkNow: () -> Void = {}
    }

    static func make(_ items: [ProviderMenuItem], alerts: AlertSettings, updates: UpdateMenu? = nil, actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "Providers")
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem.sectionHeader(title: item.name)
            menu.addItem(header)

            let show = ClosureMenuItem(title: "Show \(item.name)") { actions.setEnabled(!item.isOn, item.id) }
            show.state = item.isOn ? .on : .off
            show.subtitle = item.detail
            menu.addItem(show)

            let menuBar = ClosureMenuItem(title: "Show in menu bar") { actions.setInMenuBar(!item.inMenuBar, item.id) }
            menuBar.state = item.inMenuBar ? .on : .off
            menuBar.isEnabled = item.isOn
            menu.addItem(menuBar)

            if let key = item.key {
                let edit = ClosureMenuItem(title: "API key…") { actions.editKey(item.id) }
                edit.subtitle = key == .saved ? "Saved in your Keychain" : "Not set"
                menu.addItem(edit)
            }

            for option in item.options {
                let toggle = ClosureMenuItem(title: option.title) { actions.setOption(!option.isOn, option.id, item.id) }
                toggle.state = option.isOn ? .on : .off
                toggle.subtitle = option.detail
                toggle.isEnabled = item.isOn
                menu.addItem(toggle)
            }

            let alertsToggle = ClosureMenuItem(title: "Alerts") { actions.setAlerts(!item.alerts, item.id) }
            alertsToggle.state = item.alerts ? .on : .off
            alertsToggle.isEnabled = item.isOn
            menu.addItem(alertsToggle)
        }

        if !items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(.sectionHeader(title: "Alerts"))
        let threshold = NSMenuItem(title: "Warn at", action: nil, keyEquivalent: "")
        threshold.subtitle = "\(alerts.threshold)% used"
        let choices = NSMenu(title: "Warn at")
        choices.autoenablesItems = false
        for percent in AlertSettings.thresholds {
            let choice = ClosureMenuItem(title: "\(percent)%") { actions.setThreshold(percent) }
            choice.state = percent == alerts.threshold ? .on : .off
            choices.addItem(choice)
        }
        threshold.submenu = choices
        menu.addItem(threshold)

        let reached = ClosureMenuItem(title: "Limit reached alerts") { actions.setLimitReached(!alerts.limitReached) }
        reached.state = alerts.limitReached ? .on : .off
        menu.addItem(reached)
        let reset = ClosureMenuItem(title: "Limit reset alerts") { actions.setLimitReset(!alerts.limitReset) }
        reset.state = alerts.limitReset ? .on : .off
        menu.addItem(reset)

        if let updates {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Updates"))
            let check = ClosureMenuItem(title: "Check for updates automatically") { actions.setCheckForUpdates(!updates.checkAutomatically) }
            check.state = updates.checkAutomatically ? .on : .off
            menu.addItem(check)
            let install = ClosureMenuItem(title: "Install updates automatically") { actions.setInstallUpdates(!updates.installAutomatically) }
            install.state = updates.installAutomatically ? .on : .off
            install.isEnabled = updates.canInstallAutomatically
            install.subtitle = updates.installDetail
            menu.addItem(install)
            let now = ClosureMenuItem(title: "Check now") { actions.checkNow() }
            now.representedObject = Self.commandMarker
            now.subtitle = updates.status
            now.isEnabled = updates.canCheckNow
            menu.addItem(now)
        }
        return menu
    }

    /// Marks an item that runs a command rather than toggling, for `describe`.
    private static let commandMarker = "command"

    /// The menu as text, one line per item, for snapshot mode:
    /// "[x] Show Claude", "[ ] Show in menu bar (disabled)", and a
    /// submenu's items indented under "Warn at ▸".
    static func describe(_ menu: NSMenu, indent: String = "  ") -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if item.isSectionHeader { return item.title }
            if let submenu = item.submenu {
                var line = "\(indent)\(item.title) ▸"
                if let subtitle = item.subtitle { line += " · \(subtitle)" }
                return line + "\n" + describe(submenu, indent: indent + "    ")
            }
            let isCommand = item.title.hasSuffix("…") || item.representedObject as? String == commandMarker
            var line = isCommand ? "\(indent)\(item.title)" : "\(indent)[\(item.state == .on ? "x" : " ")] \(item.title)"
            if let subtitle = item.subtitle { line += " · \(subtitle)" }
            if !item.isEnabled { line += " (disabled)" }
            return line
        }.joined(separator: "\n")
    }
}

/// A menu item that runs a closure when chosen.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() {
        handler()
    }
}
