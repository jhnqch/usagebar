import Foundation
import OSLog
import UsageCore

/// Keeps the model's usage-endpoint reading current: asks Claude's usage
/// endpoint every 5 minutes, and when the popover opens at most once a
/// minute. `ClaudeUsagePolling` decides when to ask and what each answer
/// does; this only reads the Keychain, makes the request and reports back.
///
/// The token is read-only. It comes from Claude Code's Keychain item through
/// `/usr/bin/security`, stays in memory between polls, and goes only into
/// the request's `Authorization` header. It's never logged, written,
/// forwarded or refreshed. After a refused login it's read again at the next
/// poll, by when Claude Code may have refreshed it.
@MainActor
final class ClaudeUsageMonitor {
    private let model: AppModel
    private var polling = ClaudeUsagePolling()
    private var token: String?
    private var inFlight = false
    private var loop: Task<Void, Never>?
    private let session: URLSession
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "claude-usage")

    /// How often the timer checks whether a poll is due.
    private static let tick: Duration = .seconds(30)

    init(model: AppModel) {
        self.model = model
        // Nothing about the request or the response is kept on disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(.timer)
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    /// Opening the popover, Refresh or waking from sleep: polls if it's been
    /// a minute, unless backing off.
    func refresh() {
        Task { await poll(.popover) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        session.invalidateAndCancel()
    }

    private func poll(_ trigger: ClaudeUsagePolling.Trigger) async {
        guard !inFlight, polling.isDue(trigger, at: Date()) else { return }
        inFlight = true
        defer { inFlight = false }
        polling.start(at: Date())

        if token == nil {
            token = await Self.readToken()
        }
        let outcome: ClaudeUsagePolling.Outcome = if let token { await fetch(token) } else { .noCredentials }
        let finished = polling.finish(outcome, at: Date())
        if finished.rereadToken {
            token = nil
        }

        let reading = polling.reading
        let windows = [reading?.fiveHour.map { _ in "5h" }, reading?.sevenDay.map { _ in "wk" }, reading?.sevenDayFable.map { _ in "Fable" }]
        log.info("Claude usage endpoint: \(finished.summary, privacy: .public); windows: \(windows.compactMap(\.self), privacy: .public)")
        model.update { $0.claude = reading }
    }

    private func fetch(_ token: String) async -> ClaudeUsagePolling.Outcome {
        let request = ClaudeUsageEndpoint.request(accessToken: token, userAgent: "UsageBar/\(Self.appVersion)")
        do {
            let (body, response) = try await session.data(for: request, delegate: RefuseRedirects())
            guard let http = response as? HTTPURLResponse else { return .networkError }
            let retryAfter = ClaudeUsagePolling.retryAfter(header: http.value(forHTTPHeaderField: "Retry-After"), at: Date())
            return .response(status: http.statusCode, body: body, retryAfter: retryAfter)
        } catch {
            return .networkError
        }
    }

    /// The access token from Claude Code's Keychain item, or nil. Reading it
    /// can show a macOS Keychain prompt; this waits for the answer off the
    /// main thread.
    private nonisolated static func readToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", ClaudeUsageEndpoint.keychainService, "-w"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let secret = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let token = process.terminationStatus == 0 ? ClaudeUsageEndpoint.accessToken(fromSecret: secret) : nil
                continuation.resume(returning: token)
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

/// Keeps the token on api.anthropic.com: a redirect comes back as the answer
/// (and drops the reading) instead of being followed with the header.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
