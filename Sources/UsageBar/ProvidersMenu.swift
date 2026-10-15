import AppKit
import UsageCore

/// The Providers menu, popped up from the popover's footer: a section per
/// provider with "Show <name>" and "Show in menu bar". A key provider will
/// add its key items to its section. `ProviderSettings.menuItems` decides
/// the rows; this only builds the menu and forwards the clicks.
@MainActor
enum ProvidersMenu {
    struct Actions {
        var setEnabled: (Bool, String) -> Void
        var setInMenuBar: (Bool, String) -> Void
    }

    static func make(_ items: [ProviderMenuItem], actions: Actions) -> NSMenu {
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
        }
        return menu
    }

    /// The menu as text, one line per item, for snapshot mode:
    /// "[x] Show Claude", "[ ] Show in menu bar (disabled)".
    static func describe(_ menu: NSMenu) -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if item.isSectionHeader { return item.title }
            var line = "  [\(item.state == .on ? "x" : " ")] \(item.title)"
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
