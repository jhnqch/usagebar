import AppKit
import SwiftUI
import UsageCore

/// The status item and its popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    init(model: AppModel) {
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let host = NSHostingController(rootView: PopoverHost(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        model.onChange = { [weak self] snapshot in self?.show(snapshot.menuBar) }
        model.refresh()
        model.startTicking()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }

        LoginItem.registerOnFirstRun()
    }

    private func show(_ label: MenuBarLabel) {
        statusItem?.button?.attributedTitle = MenuBarText.attributed(label)
        statusItem?.button?.setAccessibilityLabel(MenuBarText.accessibilityLabel(label))
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refresh()
            // Follow the system's light/dark setting, not the menu bar's
            // appearance (which tracks the wallpaper).
            popover.appearance = NSApp.effectiveAppearance
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Re-renders the popover whenever the model's snapshot changes.
private struct PopoverHost: View {
    var model: AppModel

    var body: some View {
        PopoverView(
            snapshot: model.snapshot,
            onRefresh: { model.refresh() },
            onQuit: { NSApp.terminate(nil) }
        )
    }
}
