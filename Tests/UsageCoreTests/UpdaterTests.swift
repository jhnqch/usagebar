import Foundation
import Testing
import UsageCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 24 * hour
private let clock = Clock(now: now, timeZone: losAngeles)

/// Built by `scripts/build.sh` from a checkout at v1.0.0.
private let fromCheckout = BuildInfo(
    version: BuildVersion(describe: "v1.0.0"), repository: GitHubRepository("acme/usagebar"), sourcePath: "/src/usagebar"
)
/// Built from a tarball: a version and repo, but no checkout.
private let fromTarball = BuildInfo(version: BuildVersion(describe: "v1.0.0"), repository: GitHubRepository("acme/usagebar"))

private func found(_ tag: String) -> ReleaseCheck {
    .release(Release(version: SemanticVersion(tag)!, tag: tag, page: URL(string: "https://github.com/acme/usagebar/releases/tag/\(tag)")))
}

private extension Updater {
    /// A finished check at `time`.
    mutating func checked(_ result: ReleaseCheck, at time: Date = now) -> UpdateAction? {
        let started = startCheck(at: time)
        #expect(started)
        return finishCheck(result, at: time)
    }
}

@Suite("Update check schedule")
struct UpdateScheduleTests {
    @Test("the first launch checks, then not again for a day")
    func daily() {
        var updater = Updater(build: fromCheckout)
        #expect(updater.isCheckDue(at: now))
        _ = updater.checked(.noRelease)
        #expect(!updater.isCheckDue(at: now + 23 * hour))
        #expect(updater.isCheckDue(at: now + day))
    }

    @Test("a check is due a day after the saved last check, across launches")
    func remembered() {
        let store = MemoryStore()
        var updater = Updater(build: fromCheckout, settings: UpdateSettings(loadingFrom: store))
        _ = updater.checked(.noRelease)
        updater.settings.save(to: store)

        let relaunched = Updater(build: fromCheckout, settings: UpdateSettings(loadingFrom: store))
        #expect(relaunched.settings.lastCheck == now)
        #expect(!relaunched.isCheckDue(at: now + 2 * hour))
        #expect(relaunched.isCheckDue(at: now + day))
    }

    @Test("a failed answer counts as the day's check; no answer retries in an hour")
    func failures() {
        var updater = Updater(build: fromCheckout)
        _ = updater.checked(.failed("GitHub answered 403"))
        #expect(!updater.isCheckDue(at: now + 2 * hour))

        var offline = Updater(build: fromCheckout)
        _ = offline.checked(.unreachable)
        #expect(offline.settings.lastCheck == nil)
        #expect(!offline.isCheckDue(at: now + 30 * 60))
        #expect(offline.isCheckDue(at: now + hour))
    }

    @Test("a clock set back makes a check due")
    func clockSetBack() {
        var updater = Updater(build: fromCheckout)
        _ = updater.checked(.noRelease)
        #expect(updater.isCheckDue(at: now - hour))
    }

    @Test("with automatic checks off, nothing is due, but Check now still checks")
    func automaticOff() {
        var updater = Updater(build: fromCheckout, settings: UpdateSettings(checkAutomatically: false))
        #expect(!updater.isCheckDue(at: now))
        let result2 = updater.startCheck(at: now)
        #expect(result2)
        let result3 = updater.startCheck(at: now)
        #expect(!result3)  // one at a time
    }

    @Test("a build with no repo or version never checks")
    func cantCheck() {
        var updater = Updater(build: BuildInfo(version: BuildVersion(describe: "v1.0.0")))
        #expect(!updater.isCheckDue(at: now))
        let result4 = updater.startCheck(at: now)
        #expect(!result4)
        #expect(!Updater(build: BuildInfo(repository: GitHubRepository("acme/usagebar"))).isCheckDue(at: now))
    }

    @Test("settings default to checking automatically and installing by hand, and survive a relaunch")
    func settings() {
        let store = MemoryStore()
        var settings = UpdateSettings(loadingFrom: store)
        #expect(settings.checkAutomatically)
        #expect(!settings.installAutomatically)
        settings.checkAutomatically = false
        settings.installAutomatically = true
        settings.save(to: store)
        let loaded = UpdateSettings(loadingFrom: store)
        #expect(!loaded.checkAutomatically)
        #expect(loaded.installAutomatically)
        #expect(store.object(forKey: "updates.checkAutomatically") as? Bool == false)
    }
}

@Suite("Update banner")
struct UpdateBannerTests {
    @Test("a newer release offers one-click update")
    func available() throws {
        var updater = Updater(build: fromCheckout)
        let result5 = updater.checked(found("v1.1.0"))
        #expect(result5 == nil)
        let banner = try #require(updater.banner)
        #expect(banner.style == .available)
        #expect(banner.title == "Update to v1.1.0")
        #expect(banner.detail == "You have v1.0.0")
    }

    @Test("the same, an older or no release shows nothing", arguments: [found("v1.0.0"), found("v0.9.0"), .noRelease, .failed("GitHub answered 500")])
    func upToDate(result: ReleaseCheck) {
        var updater = Updater(build: fromCheckout)
        _ = updater.checked(result)
        #expect(updater.banner == nil)
    }

    @Test("a build past the release's tag isn't offered it")
    func pastTag() {
        var updater = Updater(build: BuildInfo(version: BuildVersion(describe: "v1.1.0-4-gabc1234"),
                                               repository: GitHubRepository("acme/usagebar"), sourcePath: "/src/usagebar"))
        _ = updater.checked(found("v1.1.0"))
        #expect(updater.banner == nil)
    }

    @Test("a checkout with no tags yet is offered any release")
    func untaggedCheckout() throws {
        var updater = Updater(build: BuildInfo(repository: GitHubRepository("acme/usagebar"), sourcePath: "/src/usagebar"))
        _ = updater.checked(found("v1.0.0"))
        let banner = try #require(updater.banner)
        #expect(banner.title == "Update to v1.0.0")
        #expect(banner.detail == "You have an untagged build")
    }

    @Test("a build without a checkout only notifies, with the command to run", arguments: [true, false])
    func notifyOnly(tarball: Bool) throws {
        var updater = tarball ? Updater(build: fromTarball) : Updater(build: fromCheckout, sourceExists: false)
        _ = updater.checked(found("v1.1.0"))
        #expect(!updater.canInstall)
        let banner = try #require(updater.banner)
        #expect(banner.style == .notifyOnly)
        #expect(banner.title == "UsageBar v1.1.0 is available")
        #expect(banner.command == "git fetch --tags origin && git checkout --detach v1.1.0 && scripts/build.sh")
        #expect(banner.page == URL(string: "https://github.com/acme/usagebar/releases/tag/v1.1.0"))
        let result6 = updater.startInstall()
        #expect(result6 == nil)
    }

    @Test("installing shows each step, then a failure with its log")
    func installing() throws {
        var updater = Updater(build: fromCheckout)
        _ = updater.checked(found("v1.1.0"))
        let result7 = updater.startInstall()
        #expect(result7?.tag == "v1.1.0")
        let result8 = updater.startInstall()
        #expect(result8 == nil)  // already installing
        #expect(updater.banner?.style == .working)
        #expect(updater.banner?.title == "Updating to v1.1.0…")
        #expect(updater.banner?.detail == "Checking the source folder")
        updater.advance(.building)
        #expect(updater.banner?.detail == "Building, which takes a few minutes")

        updater.fail(UpdateFailure(message: "The build failed.", logPath: "~/Library/Application Support/UsageBar/update.log"))
        let banner = try #require(updater.banner)
        #expect(banner.style == .failed)
        #expect(banner.title == "Couldn't update to v1.1.0")
        #expect(banner.detail == "The build failed.")
        #expect(banner.logPath == "~/Library/Application Support/UsageBar/update.log")
        // Try again.
        let result9 = updater.startInstall()
        #expect(result9?.tag == "v1.1.0")
    }

    @Test("no check runs while installing")
    func noCheckWhileInstalling() {
        var updater = Updater(build: fromCheckout)
        _ = updater.checked(found("v1.1.0"))
        _ = updater.startInstall()
        #expect(!updater.isCheckDue(at: now + 2 * day))
        let result10 = updater.startCheck(at: now + 2 * day)
        #expect(!result10)
    }
}

@Suite("Automatic install")
struct AutomaticInstallTests {
    @Test("with Install automatically on, a newer release installs itself")
    func installs() {
        var updater = Updater(build: fromCheckout, settings: UpdateSettings(installAutomatically: true))
        let result11 = updater.checked(found("v1.1.0"))
        #expect(result11 == .install)
    }

    @Test("not when automatic checks are off, even if Check now finds one")
    func notWithChecksOff() {
        var updater = Updater(build: fromCheckout, settings: UpdateSettings(checkAutomatically: false, installAutomatically: true))
        let action = updater.checked(found("v1.1.0"))
        #expect(action == nil)
        #expect(updater.banner?.style == .available)
    }

    @Test("not when the build can only notify, or nothing is newer")
    func notWhenNotifyOnly() {
        var tarball = Updater(build: fromTarball, settings: UpdateSettings(installAutomatically: true))
        let result12 = tarball.checked(found("v1.1.0"))
        #expect(result12 == nil)
        var current = Updater(build: fromCheckout, settings: UpdateSettings(installAutomatically: true))
        let result13 = current.checked(found("v1.0.0"))
        #expect(result13 == nil)
    }

    @Test("a release that failed to install isn't retried automatically, but a newer one is")
    func noRetryLoop() {
        var updater = Updater(build: fromCheckout, settings: UpdateSettings(installAutomatically: true))
        let result14 = updater.checked(found("v1.1.0"))
        #expect(result14 == .install)
        _ = updater.startInstall()
        updater.fail(UpdateFailure(message: "The build failed.", logPath: nil))
        let result15 = updater.checked(found("v1.1.0"), at: now + day)
        #expect(result15 == nil)
        #expect(updater.banner?.style == .failed)
        let result16 = updater.checked(found("v1.2.0"), at: now + 2 * day)
        #expect(result16 == .install)
        #expect(updater.banner?.title == "Update to v1.2.0")
    }
}

@Suite("Updates menu")
struct UpdatesMenuTests {
    @Test("before any check it says so; after one, the version and when")
    func status() {
        var updater = Updater(build: fromCheckout)
        #expect(updater.menu(clock: clock).status == "v1.0.0 · not checked yet")
        _ = updater.checked(.noRelease, at: now - 5 * 60)
        #expect(updater.menu(clock: clock).status == "v1.0.0 · up to date, checked 5 min ago")
        _ = updater.checked(found("v1.1.0"), at: now)
        #expect(updater.menu(clock: clock).status == "v1.1.0 is available")
        _ = updater.checked(.failed("GitHub answered 403"), at: now)
        #expect(updater.menu(clock: clock).status == "Couldn't check: GitHub answered 403")
    }

    @Test("Check now waits for a check underway")
    func checking() {
        var updater = Updater(build: fromCheckout)
        let result17 = updater.startCheck(at: now)
        #expect(result17)
        #expect(updater.menu(clock: clock).status == "Checking…")
        #expect(!updater.menu(clock: clock).canCheckNow)
    }

    @Test("Install automatically needs automatic checks and a source checkout")
    func installToggle() {
        #expect(Updater(build: fromCheckout).menu(clock: clock).canInstallAutomatically)
        #expect(!Updater(build: fromCheckout, settings: UpdateSettings(checkAutomatically: false)).menu(clock: clock).canInstallAutomatically)
        let tarball = Updater(build: fromTarball).menu(clock: clock)
        #expect(!tarball.canInstallAutomatically)
        #expect(tarball.installDetail == "Needs the source checkout it was built from")
    }

    @Test("a build that can't check says why")
    func cantCheck() {
        let menu = Updater(build: BuildInfo()).menu(clock: clock)
        #expect(menu.status == "Not built by scripts/build.sh from a GitHub checkout")
        #expect(!menu.canCheckNow)
    }
}

private final class MemoryStore: KeyValueStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@Suite("Update fixtures")
struct UpdateFixtureTests {
    @Test("each update fixture shows its state", arguments: [
        ("update-available", UpdateBanner.Style.available, "Update to v1.1.0", "You have v1.0.0"),
        ("update-installing", .working, "Updating to v1.1.0…", "Building, which takes a few minutes"),
        ("update-failed", .failed, "Couldn't update to v1.1.0", "The build failed."),
        ("update-notify-only", .notifyOnly, "UsageBar v1.1.0 is available", "This build can't update itself. In your UsageBar folder, run:"),
    ])
    func states(name: String, style: UpdateBanner.Style, title: String, detail: String) throws {
        let fixture = try loadFixture(name)
        let banner = try #require(fixture.update?.banner)
        #expect(banner.style == style)
        #expect(banner.title == title)
        #expect(banner.detail == detail)
        let clock = Clock(now: fixture.now, timeZone: fixture.timeZone)
        #expect(fixture.update?.menu(clock: clock).status == "v1.1.0 is available")
    }

    @Test("the failed fixture points at the log")
    func failedLog() throws {
        #expect(try loadFixture("update-failed").update?.banner?.logPath == "~/Library/Application Support/UsageBar/update.log")
    }

    @Test("fixtures without an update section, or with a broken one, have none")
    func none() throws {
        #expect(try loadFixture("sample").update == nil)
        let broken = Data(#"{"now": "2026-10-10T14:40:00-07:00", "readings": {}, "update": {"latest": 3}}"#.utf8)
        #expect(try Fixture.decode(broken).update == nil)
    }
}
