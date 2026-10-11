import Foundation
import OSLog
import UsageCore

/// Runs `codex app-server` as a child process and holds the JSON-RPC
/// conversation with it over stdio. Restarts it with backoff when it exits.
///
/// app-server is Codex's own process and refreshes Codex's login itself.
/// UsageBar never reads `~/.codex/auth.json`.
///
/// The child never outlives the app: `stop()` ends it on quit, and if the
/// app dies without quitting, its end of the stdin pipe closes and
/// app-server exits on end of input.
@MainActor
final class CodexAppServerProcess {
    /// The `codex` binary bundled inside ChatGPT.app. `USAGEBAR_CODEX`
    /// overrides it (handy for checking the session-log fallback).
    static let defaultExecutable = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["USAGEBAR_CODEX"]
            ?? "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")

    /// Called on the main actor with each new reading.
    var onLimits: ((CodexLimits) -> Void)?

    private let executable: URL
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "codex-app-server")
    private var process: Process?
    private var stdin: FileHandle?
    private var conversation = CodexAppServerConversation()
    /// Bumped on every launch so callbacks from an old process are ignored.
    private var generation = 0
    private var backoff = RestartBackoff()
    private var restart: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stopped = true

    init(executable: URL = defaultExecutable) {
        self.executable = executable
    }

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    /// Asks for a fresh reading; a no-op until the handshake completes.
    func requestRateLimits() {
        send(conversation.requestRateLimits())
    }

    /// Ends the child process and stops restarting it. Waits up to a
    /// second for it to exit, then kills it.
    func stop() {
        stopped = true
        restart?.cancel()
        watchdog?.cancel()
        generation += 1
        guard let process else { return }
        self.process = nil
        try? stdin?.close()
        stdin = nil
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        log.info("app-server stopped")
    }

    private func launch() {
        generation += 1
        let generation = generation
        conversation = CodexAppServerConversation(clientVersion: Self.appVersion)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(generation: generation, status: status) }
            }
        }
        do {
            try process.run()
        } catch {
            log.error("app-server failed to start: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
            return
        }
        self.process = process
        stdin = input.fileHandleForWriting
        log.info("app-server started, pid \(process.processIdentifier)")
        readLines(from: output.fileHandleForReading, generation: generation)
        send(conversation.start())

        // A server that never answers `initialize` is as good as dead.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.generation == generation, !self.conversation.isReady else { return }
            self.log.error("app-server didn't finish the handshake; restarting it")
            self.process?.terminate()
        }
    }

    /// Reads stdout on a background queue and hands complete lines to the
    /// main actor in order.
    private func readLines(from handle: FileHandle, generation: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self, handle] in
            // The closure owns `handle`, so its descriptor stays open until
            // the loop ends at end of output.
            defer { try? handle.close() }
            let fd = handle.fileDescriptor
            // `read(2)` returns whatever has arrived; FileHandle's
            // `read(upToCount:)` waits for the full count on a pipe.
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            var buffer = Data()
            while true {
                let count = read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: chunk[..<count])
                var lines: [Data] = []
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                // A line this long isn't one UsageBar needs.
                if buffer.count > 16 * 1024 * 1024 { buffer.removeAll() }
                guard !lines.isEmpty else { continue }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.received(lines, generation: generation) }
                }
            }
        }
    }

    private func received(_ lines: [Data], generation: Int) {
        guard generation == self.generation else { return }
        for line in lines {
            let step = conversation.receive(line, at: Date())
            send(step.send)
            if let failure = step.failure {
                log.error("\(failure, privacy: .public)")
            }
            if let limits = step.limits {
                backoff.reset()
                log.info("Codex limits from app-server: \(limits.windows.map { "\($0.windowMinutes)m" }, privacy: .public)")
                onLimits?(limits)
            }
        }
    }

    private func send(_ lines: [Data]) {
        for line in lines {
            do {
                try stdin?.write(contentsOf: line)
            } catch {
                log.error("writing to app-server failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func exited(generation: Int, status: Int32) {
        guard generation == self.generation else { return }
        process = nil
        stdin = nil
        watchdog?.cancel()
        log.error("app-server exited with status \(status)")
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped else { return }
        let delay = backoff.nextDelay()
        log.info("restarting app-server in \(delay.components.seconds)s")
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.launch()
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
