import Foundation
import OSLog
import UsageCore

/// Keeps the model's Codex readings current: app-server at launch, on its
/// pushes and every 5 minutes; the session logs every 30 seconds.
///
/// app-server only pushes for turns it runs itself, so turns in Codex CLI or
/// the ChatGPT app reach UsageBar through the session logs (each turn writes
/// a record) and through the periodic read.
@MainActor
final class CodexMonitor {
    private let model: AppModel
    private let appServer: CodexAppServerProcess
    private let sessionLog: CodexSessionLogReader
    private var loop: Task<Void, Never>?
    private var lastRead = Date.distantPast
    private var lastSessionLog: CodexLimits?
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "codex-session-log")

    private static let readInterval: TimeInterval = 5 * 60
    /// Opening the popover reads again at most this often.
    private static let minimumReadGap: TimeInterval = 60
    private static let scanInterval: Duration = .seconds(30)

    init(model: AppModel, appServer: CodexAppServerProcess = CodexAppServerProcess(), sessionLog: CodexSessionLogReader = CodexSessionLogReader()) {
        self.model = model
        self.appServer = appServer
        self.sessionLog = sessionLog
    }

    func start() {
        guard loop == nil else { return }
        appServer.onReading = { [weak model] limits in
            model?.update(CodexProvider.self) { $0.appServer = limits }
        }
        // The handshake reads once by itself.
        lastRead = Date()
        appServer.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanSessionLog()
                if let self, Date().timeIntervalSince(self.lastRead) >= Self.readInterval {
                    self.read()
                }
                try? await Task.sleep(for: Self.scanInterval)
            }
        }
    }

    /// Reads both sources now. Without `force`, app-server is read at most
    /// once a minute (opening the popover, waking from sleep).
    func refresh(force: Bool) {
        guard loop != nil else { return }
        if force || Date().timeIntervalSince(lastRead) >= Self.minimumReadGap {
            read()
        }
        Task { await scanSessionLog() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        appServer.stop()
    }

    private func read() {
        lastRead = Date()
        appServer.requestRateLimits()
    }

    private func scanSessionLog() async {
        let limits = await sessionLog.latest()
        // Stopped (Codex turned off) while scanning.
        guard loop != nil else { return }
        if limits != lastSessionLog {
            lastSessionLog = limits
            log.info("Codex limits from session log: \(limits?.windows.map { "\($0.windowMinutes)m" } ?? [], privacy: .public)")
        }
        model.update(CodexProvider.self) { $0.sessionLog = limits }
    }
}
