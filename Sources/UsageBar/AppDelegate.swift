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
    /// One per key provider UsageBar ships, by provider id.
    private let keyMonitors: [String: any KeyMonitoring]
    private let keyWindow = APIKeyWindow()
    private let notifier = LimitNotifier()
    private let updates = UpdateController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let popoverFit = PopoverFit()
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "menu-bar")
    /// The providers whose monitors are running.
    private var running: Set<String> = []

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
        let transport = URLSessionTransport()
        keyMonitors = Dictionary(uniqueKeysWithValues: BuiltInProviders.keyAPIs.map { api in
            let monitor = api.monitor(model: model, store: model.environment.keys, transport: transport)
            monitor.setOptions(model.enabledOptions(for: api.id))
            return (api.id, monitor)
        })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let host = NSHostingController(rootView: PopoverHost(
            model: model, updates: updates, fit: popoverFit,
            onRefresh: { [weak self] in self?.refresh(force: true) },
            onEditKey: { [weak self] id in self?.editKey(id) }
        ))
        model.onSelectionChange = { [weak self] selection in self?.run(selection) }
        model.onOptionsChange = { [weak self] id, options in self?.keyMonitors[id]?.setOptions(options) }
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
        model.onTick = { [updates] in updates.tick() }
        model.refresh()
        model.startTicking()
        run(model.selection)
        updates.tick()

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
        run(ProviderSelection(enabled: [], menuBar: []), quitting: true)
    }

    /// Starts the monitors of the providers that are on and stops the rest:
    /// a provider that's off runs no app-server, polls nothing and never
    /// reads the Keychain.
    private func run(_ selection: ProviderSelection, quitting: Bool = false) {
        let wanted = Set(selection.enabled)
        for id in running.subtracting(wanted) {
            log.info("stopping \(id, privacy: .public)")
            switch id {
            case ClaudeProvider.info.id:
                claudeStatusLine.stop()
                claudeUsage.stop()
                claudeUsageLog.stop()
            case CodexProvider.info.id:
                codex.stop(wait: quitting)
                codexUsageLog.stop()
            default:
                keyMonitors[id]?.stop()
            }
        }
        for id in wanted.subtracting(running) {
            log.info("starting \(id, privacy: .public)")
            switch id {
            case ClaudeProvider.info.id:
                claudeStatusLine.start()
                claudeUsage.start()
                claudeUsageLog.start()
            case CodexProvider.info.id:
                codex.start()
                codexUsageLog.start()
            default:
                keyMonitors[id]?.start()
            }
        }
        running = wanted
    }

    /// Stopped monitors ignore their refresh.
    private func refresh(force: Bool) {
        updates.tick()
        model.detectProviders()
        model.refresh()
        claudeStatusLine.refresh()
        // Even Refresh asks the rate-limited usage endpoint at most once a minute.
        claudeUsage.refresh()
        claudeUsageLog.refresh()
        codexUsageLog.refresh()
        codex.refresh(force: force)
        // Key providers too ask at most once a minute.
        keyMonitors.values.forEach { $0.refresh() }
    }

    /// Opens a key provider's key window. Saving or removing the key looks
    /// for providers again (a saved key turns its provider on) and polls.
    private func editKey(_ id: String) {
        guard let monitor = keyMonitors[id] else { return }
        let keys = model.environment.keys
        let changed = { [weak self, weak monitor] in
            self?.model.detectProviders()
            monitor?.keyChanged()
        }
        popover.performClose(nil)
        keyWindow.show(name: monitor.info.name, hint: monitor.keyHint, actions: APIKeyActions(
            save: { key in
                try keys.save(key, for: id)
                changed()
            },
            remove: {
                try keys.removeKey(for: id)
                changed()
            },
            test: { [weak monitor] key in await monitor?.testConnection(key: key) ?? .noKey },
            hasKey: { keys.hasKey(for: id) }
        ))
    }

    private func show(_ label: MenuBarLabel) {
        if statusItem?.button?.accessibilityLabel() != MenuBarText.accessibilityLabel(label) {
            log.info("menu bar: \(label.text, privacy: .public)")
        }
        statusItem?.button?.attributedTitle = MenuBarText.attributed(label)
        // With no part to show, a neutral icon keeps the status item clickable.
        statusItem?.button?.image = label.parts.isEmpty ? MenuBarText.neutralIcon : nil
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
    var updates: UpdateController
    var fit: PopoverFit
    var onRefresh: () -> Void
    var onEditKey: (String) -> Void

    var body: some View {
        PopoverView(
            snapshot: model.snapshot,
            height: .capped(fit.maxHeight),
            update: updates.banner,
            updateActions: updates.actions,
            onShowProviders: {
                ProvidersMenu.make(model.providerItems, alerts: model.alertSettings, updates: updates.menu(), actions: ProvidersMenu.Actions(
                    setEnabled: { model.setEnabled($0, for: $1) },
                    setInMenuBar: { model.setInMenuBar($0, for: $1) },
                    editKey: onEditKey,
                    setOption: { model.setOption($0, $1, for: $2) },
                    setAlerts: { model.setAlerts($0, for: $1) },
                    setThreshold: { model.setAlertThreshold($0) },
                    setLimitReached: { model.setLimitReachedAlerts($0) },
                    setLimitReset: { model.setLimitResetAlerts($0) },
                    setCheckForUpdates: { updates.setCheckAutomatically($0) },
                    setInstallUpdates: { updates.setInstallAutomatically($0) },
                    checkNow: { updates.checkNow() }
                )).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            },
            onRefresh: onRefresh,
            onQuit: { NSApp.terminate(nil) }
        )
    }
}
