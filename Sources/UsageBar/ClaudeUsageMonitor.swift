import Foundation
import OSLog
import UsageCore

/// Keeps the model's usage-endpoint reading current: asks Claude's usage
/// endpoint every 5 minutes, and when the popover opens at most once a
/// minute. `ClaudeUsagePoller` decides when to ask, what each answer does
/// and when to read the login again; this only reads the Keychain, makes the
/// request and reports back.
///
/// The token is read-only. It comes from Claude Code's Keychain item through
/// `/usr/bin/security`, stays in memory between polls, and goes only into
/// the request's `Authorization` header. It's never logged, written,
/// forwarded or refreshed. After a refused login it's read again at once,
/// in case Claude Code has rotated it, and otherwise at the next poll.
@MainActor
final class ClaudeUsageMonitor {
    private let model: AppModel
    private let poller: ClaudeUsagePoller
    private var loop: Task<Void, Never>?
    /// Between `start()` and `stop()`. While stopped (Claude turned off)
    /// nothing reads the Keychain or asks the endpoint.
    private var running = false
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
        poller = ClaudeUsagePoller(
            readLogin: { await Self.readLogin() },
            fetch: { [session] token in await Self.fetch(token, session: session) },
            log: { [log] line in log.info("Claude usage endpoint: \(line, privacy: .public)") }
        )
    }

    func start() {
        running = true
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
        guard running else { return }
        Task { await poll(.popover) }
    }

    /// Stops polling and forgets the token. A poll under way is cancelled
    /// and its answer dropped; `start()` begins again.
    func stop() {
        running = false
        loop?.cancel()
        loop = nil
        poller.stop()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    private func poll(_ trigger: ClaudeUsagePolling.Trigger) async {
        guard running, await poller.poll(trigger), running else { return }
        let reading = poller.reading
        let windows = [reading?.fiveHour.map { _ in "5h" }, reading?.sevenDay.map { _ in "wk" }, reading?.sevenDayFable.map { _ in "Fable" }]
        log.info("Claude usage endpoint windows: \(windows.compactMap(\.self), privacy: .public)")
        // The plan badge comes from the same saved login (the tokens stay
        // in the poller); with no readable login there's no badge.
        let plan = poller.plan
        model.update(ClaudeProvider.self) {
            $0.plan = plan
            $0.endpoint = reading
        }
    }

    private nonisolated static func fetch(_ token: String, session: URLSession) async -> PollOutcome {
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

    /// The access token and plan from Claude Code's Keychain item, or nil.
    /// Reading it can show a macOS Keychain prompt; this waits for the
    /// answer off the main thread.
    private nonisolated static func readLogin() async -> ClaudeLogin? {
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
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ClaudeLogin(
                    token: ClaudeUsageEndpoint.accessToken(fromSecret: secret), plan: ClaudeUsageEndpoint.plan(fromSecret: secret)
                ))
            }
        }
    }

    private nonisolated static var appVersion: String {
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
