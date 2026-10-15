import Foundation
import OSLog
import UsageCore

/// What the app does with any key provider's monitor.
@MainActor
protocol KeyMonitoring: AnyObject {
    var info: ProviderInfo { get }
    var keyHint: String? { get }
    func start()
    func stop()
    /// Opening the popover, Refresh, waking: polls if it's been a minute.
    func refresh()
    /// The key was saved or removed: poll again at once.
    func keyChanged()
    func testConnection(key: String?) async -> ConnectionTest
}

/// Keeps one key provider's readings current. `KeyPoller` decides when to
/// ask, holds the key and applies the answers; this runs its timer and
/// hands the readings to the model. Stopped (provider off), it polls
/// nothing and forgets the key.
@MainActor
final class KeyProviderMonitor<API: KeyAPI>: KeyMonitoring {
    private let model: AppModel
    private let poller: KeyPoller<API>
    private var loop: Task<Void, Never>?
    private var running = false

    /// How often the timer checks whether a poll is due.
    private static var tick: Duration { .seconds(30) }

    var info: ProviderInfo { API.info }
    var keyHint: String? { API.keyHint }

    init(model: AppModel, store: any KeyStore, transport: any HTTPTransport) {
        self.model = model
        let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "key-provider")
        // Poller summaries never hold the key or a response body.
        poller = KeyPoller<API>(store: store, transport: transport, userAgent: "UsageBar/\(Self.appVersion)", log: { line in
            log.info("\(line, privacy: .public)")
        })
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

    func stop() {
        running = false
        loop?.cancel()
        loop = nil
        poller.stop()
    }

    func refresh() {
        guard running else { return }
        Task { await poll(.popover) }
    }

    func keyChanged() {
        poller.keyChanged()
        let provider = poller.provider
        model.update(KeyProvider<API>.self) { $0 = provider }
        refresh()
    }

    func testConnection(key: String?) async -> ConnectionTest {
        await poller.testConnection(key: key)
    }

    private func poll(_ trigger: PollTrigger) async {
        guard running, await poller.poll(trigger), running else { return }
        let provider = poller.provider
        model.update(KeyProvider<API>.self) { $0 = provider }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

extension KeyAPI {
    /// A monitor for this API, for the app's list of key monitors.
    @MainActor
    static func monitor(model: AppModel, store: any KeyStore, transport: any HTTPTransport) -> any KeyMonitoring {
        KeyProviderMonitor<Self>(model: model, store: store, transport: transport)
    }
}
