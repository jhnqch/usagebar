import Foundation
import OSLog
import UsageCore
import UserNotifications

/// Posts the engine's alerts as macOS notifications. Asks for permission the
/// first time an alert needs it, at most once a launch; once denied, alerts
/// are dropped quietly (the engine has already remembered them).
@MainActor
final class LimitNotifier: NSObject {
    /// Clicking a notification.
    var onOpen: (() -> Void)?

    private let center: UNUserNotificationCenter?
    private var waiting: [LimitAlert] = []
    private var posting = false
    private var askedThisLaunch = false
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "alerts")

    override init() {
        // The notification center needs an app bundle; a bare binary (say,
        // from `swift run`) has none, and asking for the center would throw.
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    func post(_ alerts: [LimitAlert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            log.info("alert: \(alert.title, privacy: .public) (\(alert.body, privacy: .public))")
        }
        guard center != nil else { return }
        waiting += alerts
        // Alerts that come in while permission is being asked for wait for the answer.
        guard !posting else { return }
        posting = true
        Task {
            let allowed = await allowed()
            let alerts = waiting
            waiting = []
            posting = false
            guard allowed else {
                log.info("notifications aren't allowed; \(alerts.count) alert(s) not shown")
                return
            }
            for alert in alerts {
                await add(alert)
            }
        }
    }

    /// Whether notifications may be posted, asking the first time.
    private func allowed() async -> Bool {
        guard let center else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined where !askedThisLaunch:
            askedThisLaunch = true
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                log.error("can't ask for notification permission: \(error, privacy: .public)")
                return false
            }
        default:
            return false
        }
    }

    private func add(_ alert: LimitAlert) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
        } catch {
            log.error("can't post \(alert.title, privacy: .public): \(error, privacy: .public)")
        }
    }
}

extension LimitNotifier: UNUserNotificationCenterDelegate {
    /// Shows alerts as banners even while the popover is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Clicking an alert opens the popover.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { onOpen?() }
    }
}

/// The alert memory's file in UsageBar's support directory.
enum AlertMemoryFile {
    static let url = ClaudeStatusLine
        .supportDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
        .appending(path: AlertMemory.fileName)

    /// The saved memory; empty when there's none or it can't be read.
    static func load(from url: URL = url) -> AlertMemory {
        (try? Data(contentsOf: url)).map(AlertMemory.decode) ?? AlertMemory()
    }

    static func save(_ memory: AlertMemory, to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try memory.encoded().write(to: url, options: .atomic)
    }
}
