import Foundation
import Testing
import UsageCore

/// The README's "Using UsageBar" guide against the names the code uses, so a
/// renamed file, setting or menu item can't leave the steps out of date.
@Suite("README usage guide")
struct ReadmeTests {
    private func section(_ heading: String) throws -> String {
        let readme = try String(contentsOfFile: "\(repoRoot)/README.md", encoding: .utf8)
        let start = try #require(readme.range(of: "\n\(heading)\n"), "README has no \(heading)")
        let rest = readme[start.upperBound...]
        let end = rest.range(of: "\n### ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("the uninstall steps remove everything UsageBar creates")
    func uninstall() throws {
        let steps = try section("### 9. Uninstall")
        let created = [
            // The app, and the copies an interrupted update's swap leaves beside it (`Relaunch`).
            "~/Applications/UsageBar.app", "UsageBar.app.new", "UsageBar.app.previous",
            // The login item (`LoginItem`).
            "Login Items",
            // API keys (`KeychainKeyStore.service`); Claude Code's item is named to be left alone.
            "security delete-generic-password -s io.github.jhnqch.usagebar.api-key",
            ClaudeUsageEndpoint.keychainService,
            // Settings in UserDefaults under the bundle id.
            "defaults delete io.github.jhnqch.usagebar",
            // The support directory and what's in it.
            "~/Library/Application\\ Support/UsageBar",
            ClaudeStatusLine.fileName, AlertMemory.fileName, "update.log", "Update/", Relaunch.statusFileName,
            // The status line entry and the installer's backups (`Installer`).
            "\"statusLine\"", "usagebar-statusline", "settings.json.usagebar-backup-",
        ]
        for name in created {
            #expect(steps.contains(name), "the uninstall steps don't mention \(name)")
        }
    }

    @Test("the guide names the Providers menu's items as the menu shows them")
    func menuItems() throws {
        let guide = try section("### 5. Choose what's shown: the Providers menu")
            + section("### 7. Set up alerts") + section("### 8. Update")
        let items = [
            "Show in menu bar", "API key…", "Alerts", "Quota meter and plan", "Warn at",
            "Limit reached alerts", "Limit reset alerts",
            "Check for updates automatically", "Install updates automatically", "Check now",
        ]
        for item in items {
            #expect(guide.contains("**\(item)**") || guide.contains("\"\(item)\""), "the guide doesn't name \(item)")
        }
        #expect(AlertSettings.thresholds.allSatisfy { guide.contains("\($0)") })
    }
}
