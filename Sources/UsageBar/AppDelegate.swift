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
    private let claudeUsageLog: UsageLogMonitor<ClaudeTranscript.Parser, ClaudeProvider>
    private let codexUsageLog: UsageLogMonitor<CodexRollout.Parser, CodexProvider>
    private let notifier = LimitNotifier()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let popoverFit = PopoverFit()
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "menu-bar")

    init(model: AppModel) {
        self.model = model
        codex = CodexMonitor(model: model)
        claudeStatusLine = ClaudeStatusLineMonitor(model: model)
        claudeUsage = ClaudeUsageMonitor(model: model)
        claudeUsageLog = UsageLogMonitor(
            model: model, reader: UsageLogReader(directories: UsageLogs.claudeProjects), name: "Claude Code", usage: \ClaudeProvider.usage
        )
        codexUsageLog = UsageLogMonitor(
            model: model, reader: UsageLogReader(directories: UsageLogs.codexSessions), name: "Codex", usage: \CodexProvider.usage
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let host = NSHostingController(rootView: PopoverHost(model: model, fit: popoverFit) { [weak self] in self?.refresh(force: true) })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        model.onChange = { [weak self] snapshot in self?.show(snapshot.menuBar) }
        model.onAlertMemoryChange = { [log] memory in
            do {
                try AlertMemoryFile.save(memory)
            } catch {
                log.error("can't save the alert memory: \(error, privacy: .public)")
            }
        }
        model.onAlerts = { [notifier] alerts in notifier.post(alerts) }
        notifier.onOpen = { [weak self] in self?.showPopover() }
        model.refresh()
        model.startTicking()
        claudeStatusLine.start()
        claudeUsage.start()
        claudeUsageLog.start()
        codexUsageLog.start()
        codex.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
        // A display added, removed or rearranged, or the Dock moving, can
        // change the room under the status item.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitPopover() }
        }

        LoginItem.registerOnFirstRun()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No orphaned app-server after quitting.
        codex.stop()
        claudeStatusLine.stop()
        claudeUsage.stop()
        claudeUsageLog.stop()
        codexUsageLog.stop()
    }

    private func refresh(force: Bool) {
        model.refresh()
        claudeStatusLine.refresh()
        // Even Refresh asks the rate-limited usage endpoint at most once a minute.
        claudeUsage.refresh()
        claudeUsageLog.refresh()
        codexUsageLog.refresh()
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
            showPopover()
        }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        refresh(force: false)
        fitPopover()
        // Follow the system's light/dark setting, not the menu bar's
        // appearance (which tracks the wallpaper).
        popover.appearance = NSApp.effectiveAppearance
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Caps the popover to the screen the status item is on; past that, its
    /// sections scroll.
    private func fitPopover() {
        popoverFit.maxHeight = PopoverFit.maxHeight(on: statusItem?.button?.window?.screen ?? NSScreen.main)
    }
}

/// Re-renders the popover whenever the model's snapshot or its height cap changes.
private struct PopoverHost: View {
    var model: AppModel
    var fit: PopoverFit
    var onRefresh: () -> Void

    var body: some View {
        PopoverView(
            snapshot: model.snapshot,
            height: .capped(fit.maxHeight),
            onRefresh: onRefresh,
            onQuit: { NSApp.terminate(nil) }
        )
    }
}
