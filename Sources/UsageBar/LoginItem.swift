import Foundation
import OSLog
import ServiceManagement

/// Registers the app to start at login the first time it runs. After that
/// the user's choice in System Settings › General › Login Items stands.
enum LoginItem {
    private static let registeredKey = "registeredLoginItem"
    private static let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "login-item")

    @MainActor
    static func registerOnFirstRun(defaults: UserDefaults = .standard) {
        // Only a packaged .app can be a login item (not `swift run`).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard !defaults.bool(forKey: registeredKey) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status != .enabled {
                try service.register()
            }
            defaults.set(true, forKey: registeredKey)
            log.info("Registered login item; status \(String(describing: service.status.rawValue), privacy: .public)")
        } catch {
            log.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
