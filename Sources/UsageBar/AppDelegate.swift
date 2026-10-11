import AppKit
import OSLog
import SwiftUI
import UsageCore

/// The status item and its popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let codex: CodexMonitor
    private let claudeStatusLine: ClaudeStatusLineMonitor
    private let claudeUsage: ClaudeUsageMonitor
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "menu-bar")

    init(model: AppModel) {
        self.model = model
        codex = CodexMonitor(model: model)
        claudeStatusLine = ClaudeStatusLineMonitor(model: model)
        claudeUsage = ClaudeUsageMonitor(model: model)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let host = NSHostingController(rootView: PopoverHost(model: model) { [weak self] in self?.refresh(force: true) })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        model.onChange = { [weak self] snapshot in self?.show(snapshot.menuBar) }
        model.refresh()
        model.startTicking()
        claudeStatusLine.start()
        claudeUsage.start()
        codex.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }

        LoginItem.registerOnFirstRun()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No orphaned app-server after quitting.
        codex.stop()
        claudeStatusLine.stop()
        claudeUsage.stop()
    }

    private func refresh(force: Bool) {
        model.refresh()
        claudeStatusLine.refresh()
        // Even Refresh asks the rate-limited usage endpoint at most once a minute.
        claudeUsage.refresh()
        codex.refresh(force: force)
    }

    private func show(_ label: MenuBarLabel) {
        if statusItem?.button?.accessibilityLabel() != MenuBarText.accessibilityLabel(label) {
            log.info("menu bar: \(label.text, privacy: .public)")
        }
        statusItem?.button?.attributedTitle = MenuBarText.attributed(label)
        statusItem?.button?.setAccessibilityLabel(MenuBarText.accessibilityLabel(label))
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refresh(force: false)
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
    var onRefresh: () -> Void

    var body: some View {
        PopoverView(
            snapshot: model.snapshot,
            onRefresh: onRefresh,
            onQuit: { NSApp.terminate(nil) }
        )
    }
}
