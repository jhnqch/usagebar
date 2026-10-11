import Foundation
import OSLog
import UsageCore

/// Keeps the model's Claude Code usage current: rescans the transcripts
/// every 3 minutes, and when the popover opens at most every 30 seconds.
/// The scan runs on `ClaudeTranscriptReader`'s actor, off the main thread;
/// only the result comes back here to update the model.
@MainActor
final class ClaudeUsageLogMonitor {
    private let model: AppModel
    private let reader: ClaudeTranscriptReader
    private var loop: Task<Void, Never>?
    private var scanning = false
    private var lastScan = Date.distantPast
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "claude-usage-log")

    private static let interval: Duration = .seconds(180)
    private static let minimumGap: TimeInterval = 30
    /// How far back to keep replies: past the start of any weekly window
    /// (at most 7 days ago) and of the last 7 local days.
    private static let lookback: TimeInterval = 8 * 24 * 60 * 60

    init(model: AppModel, reader: ClaudeTranscriptReader = ClaudeTranscriptReader()) {
        self.model = model
        self.reader = reader
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
        guard Date().timeIntervalSince(lastScan) >= Self.minimumGap else { return }
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
        log.info("Claude transcripts: \(entries.count, privacy: .public) replies in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        model.update { $0.claudeUsage = entries }
    }
}
