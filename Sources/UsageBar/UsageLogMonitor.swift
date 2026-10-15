import Foundation
import OSLog
import UsageCore

/// Keeps one tool's usage in the model current: rescans its logs every 3
/// minutes, and when the popover opens at most every 30 seconds. The scan
/// runs on `UsageLogReader`'s actor, off the main thread; only the result
/// comes back here to update the model.
@MainActor
final class UsageLogMonitor<Parser: UsageLogParser, Owner: Provider> {
    private let model: AppModel
    private let reader: UsageLogReader<Parser>
    private let name: String
    private let usage: WritableKeyPath<Owner, [UsageEntry]>
    private var loop: Task<Void, Never>?
    private var scanning = false
    private var lastScan = Date.distantPast
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "usage-log")

    private static var interval: Duration { .seconds(180) }
    private static var minimumGap: TimeInterval { 30 }
    /// How far back to keep usage: past the start of any weekly window (at
    /// most 7 days ago) and of the last 7 local days.
    private static var lookback: TimeInterval { 8 * 24 * 60 * 60 }

    /// Scans `reader`'s logs into the provider readings at `usage`; `name`
    /// labels the log lines.
    init(model: AppModel, reader: UsageLogReader<Parser>, name: String, usage: WritableKeyPath<Owner, [UsageEntry]>) {
        self.model = model
        self.reader = reader
        self.name = name
        self.usage = usage
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Opening the popover, Refresh or waking from sleep.
    func refresh() {
        guard loop != nil, Date().timeIntervalSince(lastScan) >= Self.minimumGap else { return }
        Task { await scan() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        lastScan = Date()
        let started = ContinuousClock.now
        let entries = await reader.scan(since: Date() - Self.lookback)
        // Stopped (its provider turned off) while scanning.
        guard loop != nil else { return }
        log.info("\(self.name, privacy: .public) logs: \(entries.count, privacy: .public) entries in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        let usage = usage
        model.update(Owner.self) { $0[keyPath: usage] = entries }
    }
}
