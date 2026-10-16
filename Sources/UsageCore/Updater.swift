import Foundation

/// The Updates section of the Providers menu, plus when the last check
/// was. The app keeps it in `UserDefaults`.
public struct UpdateSettings: Equatable, Sendable {
    /// Check GitHub for a newer release once a day.
    public var checkAutomatically: Bool
    /// Install a newer release as soon as a check finds it.
    public var installAutomatically: Bool
    /// When GitHub last answered a check.
    public internal(set) var lastCheck: Date?
    /// The release that check found, so a relaunch still offers it.
    public internal(set) var latest: Release?
    /// The repo `lastCheck` and `latest` are about, `owner/name`.
    public internal(set) var checkedRepository: String?
    /// A release whose install failed: not installed automatically again.
    public internal(set) var failedTag: String?

    public init(checkAutomatically: Bool = true, installAutomatically: Bool = false, lastCheck: Date? = nil, latest: Release? = nil,
                checkedRepository: String? = nil, failedTag: String? = nil) {
        self.checkAutomatically = checkAutomatically
        self.installAutomatically = installAutomatically
        self.lastCheck = lastCheck
        self.latest = latest
        self.checkedRepository = checkedRepository
        self.failedTag = failedTag
    }

    static let checkKey = "updates.checkAutomatically"
    static let installKey = "updates.installAutomatically"
    static let lastCheckKey = "updates.lastCheck"
    static let latestTagKey = "updates.latestTag"
    static let latestPageKey = "updates.latestPage"
    static let checkedRepositoryKey = "updates.checkedRepository"
    static let failedTagKey = "updates.failedTag"

    /// The settings saved in `store`; a missing or mistyped value reads as
    /// the default.
    public init(loadingFrom store: some KeyValueStore) {
        self.init(
            checkAutomatically: (store.object(forKey: Self.checkKey) as? Bool) ?? true,
            installAutomatically: (store.object(forKey: Self.installKey) as? Bool) ?? false,
            lastCheck: store.object(forKey: Self.lastCheckKey) as? Date,
            latest: (store.object(forKey: Self.latestTagKey) as? String).flatMap { tag in
                Release(tag: tag, page: store.object(forKey: Self.latestPageKey) as? String)
            },
            checkedRepository: store.object(forKey: Self.checkedRepositoryKey) as? String,
            failedTag: store.object(forKey: Self.failedTagKey) as? String
        )
    }

    public func save(to store: some KeyValueStore) {
        store.set(checkAutomatically, forKey: Self.checkKey)
        store.set(installAutomatically, forKey: Self.installKey)
        store.set(lastCheck, forKey: Self.lastCheckKey)
        store.set(latest?.tag, forKey: Self.latestTagKey)
        store.set(latest?.page?.absoluteString, forKey: Self.latestPageKey)
        store.set(checkedRepository, forKey: Self.checkedRepositoryKey)
        store.set(failedTag, forKey: Self.failedTagKey)
    }
}

/// What the app should do after a check.
public enum UpdateAction: Equatable, Sendable {
    /// Install the available release (Install automatically is on).
    case install
}

/// A step of the one-click update.
public enum UpdateStep: String, Equatable, Sendable, Decodable {
    case checkingSource, fetching, checkingOut, building, relaunching
}

/// Why an update stopped. The running app is untouched.
public struct UpdateFailure: Equatable, Sendable, Error {
    /// A sentence for the popover: "The build failed."
    public var message: String
    /// Where the update's log is, for "Show log"; nil when none was written.
    public var logPath: String?

    public init(message: String, logPath: String?) {
        self.message = message
        self.logPath = logPath
    }
}

/// The update line above the popover's footer.
public struct UpdateBanner: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// A newer release, one click away: "Update to v1.1.0".
        case available
        /// A newer release this build can't install itself; shows `command`.
        case notifyOnly
        /// An update underway.
        case working
        /// The last update stopped; can be tried again.
        case failed
    }

    public var style: Style
    public var title: String
    public var detail: String?
    /// Notify-only: the commands to run in the source folder.
    public var command: String?
    /// The release's page on github.com.
    public var page: URL?
    /// Failed: where the log is.
    public var logPath: String?
}

/// The Updates section's state, for the Providers menu.
public struct UpdateMenu: Equatable, Sendable {
    public var checkAutomatically: Bool
    public var installAutomatically: Bool
    /// Whether "Install updates automatically" can be turned on.
    public var canInstallAutomatically: Bool
    /// Why it can't, when it's for good; nil otherwise.
    public var installDetail: String?
    public var canCheckNow: Bool
    /// "v1.0.0 · up to date, checked 5 min ago".
    public var status: String
}

/// Updates from source: when to check GitHub for a newer release, what the
/// popover and menu say about it, and the one-click update's progress. Pure
/// state; the app runs the check (`GitHubRelease`) and the update
/// (`UpdateRunner`) and reports back.
public struct Updater: Equatable, Sendable {
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// After no answer at all (offline), the next try.
    public static let retryInterval: TimeInterval = 60 * 60

    public var build: BuildInfo
    public var settings: UpdateSettings
    /// Whether the recorded source checkout is still there; the app looks.
    public var sourceExists: Bool

    /// The release the last check found.
    public var latest: Release? { settings.latest }
    private var phase = Phase.idle
    private var isChecking = false
    private var lastAttempt: Date?
    private var checkError: String?

    private enum Phase: Equatable, Sendable {
        case idle
        case installing(Release, UpdateStep)
        case failed(Release, UpdateFailure)
    }

    /// A saved check about another repo (a fork's build replacing an
    /// upstream one) is forgotten.
    public init(build: BuildInfo, settings: UpdateSettings = UpdateSettings(), sourceExists: Bool = true) {
        self.build = build
        self.settings = settings
        self.sourceExists = sourceExists
        if settings.checkedRepository != build.repository?.description {
            self.settings.lastCheck = nil
            self.settings.latest = nil
            self.settings.checkedRepository = nil
            self.settings.failedTag = nil
        }
    }

    // MARK: Checking

    /// Whether there's a repo to ask and a version to compare: a recorded
    /// version, or a source checkout (an untagged one takes any release).
    public var canCheck: Bool {
        build.repository != nil && (build.version != nil || build.sourcePath != nil)
    }

    /// Whether an automatic check is due: at most once a day, an hour after
    /// a try that got no answer, and never while checking or installing.
    public func isCheckDue(at now: Date) -> Bool {
        guard settings.checkAutomatically, canCheck, allowsCheck else { return false }
        if let lastAttempt, now >= lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryInterval { return false }
        guard let last = settings.lastCheck, now >= last else { return true }
        return now.timeIntervalSince(last) >= Self.checkInterval
    }

    /// A check starts now, automatic or "Check now". False when one can't:
    /// no repo, or a check or update already underway.
    public mutating func startCheck(at now: Date) -> Bool {
        guard canCheck, allowsCheck else { return false }
        isChecking = true
        lastAttempt = now
        return true
    }

    /// The check's result. Returns `.install` when both automatic settings
    /// are on and a newer release this build can install was found, unless
    /// that release already failed to install.
    public mutating func finishCheck(_ result: ReleaseCheck, at now: Date) -> UpdateAction? {
        isChecking = false
        switch result {
        case .release, .noRelease:
            if case let .release(release) = result { settings.latest = release } else { settings.latest = nil }
            checkError = nil
            // A failed install gives way to a newer release, or to none
            // when its release was withdrawn.
            if case let .failed(release, _) = phase, available?.version != release.version {
                phase = .idle
            }
        case let .failed(message):
            checkError = message
        case .unreachable:
            checkError = "GitHub didn't answer"
            return nil
        }
        // GitHub answered, about this build's repo.
        settings.lastCheck = now
        settings.checkedRepository = build.repository?.description
        lastAttempt = nil
        // Installing automatically rides on checking automatically, as the menu shows.
        // Only a release this check found, and not one that failed before.
        guard case .release = result, settings.installAutomatically, settings.checkAutomatically, canInstall, phase == .idle,
              let available, available.tag != settings.failedTag
        else { return nil }
        return .install
    }

    /// A release newer than this build, from the last check.
    public var available: Release? {
        guard let latest else { return nil }
        if let version = build.version, !version.isOlder(than: latest.version) { return nil }
        return latest
    }

    /// Whether this build can update itself: built by `scripts/build.sh`
    /// from a GitHub checkout that's still there.
    public var canInstall: Bool {
        build.repository != nil && build.sourcePath != nil && sourceExists
    }

    // MARK: Installing

    /// The one-click update starts: returns the release to install, or nil
    /// when there's none, this build only notifies, or one is underway.
    public mutating func startInstall() -> Release? {
        // "Try again" retries the failed release, even when no check since
        // a relaunch has found it again.
        var target = available
        if case let .failed(release, _) = phase { target = release }
        guard canInstall, let target else { return nil }
        guard allowsCheck else { return nil }
        phase = .installing(target, .checkingSource)
        return target
    }

    /// The update reached `step`.
    public mutating func advance(_ step: UpdateStep) {
        if case let .installing(release, _) = phase { phase = .installing(release, step) }
    }

    /// The update stopped; the running app is untouched.
    public mutating func fail(_ failure: UpdateFailure) {
        guard case let .installing(release, _) = phase else { return }
        phase = .failed(release, failure)
        settings.failedTag = release.tag
    }

    /// The relaunch helper couldn't swap the built `tag` into place and
    /// reopened this, the old build (`Relaunch.takeFailedTag`). Shows the
    /// failure, as a failed build does, and keeps the release from being
    /// installed automatically again; "Try again" still can. False, and
    /// nothing changes, when `tag` isn't a release newer than this build.
    @discardableResult
    public mutating func swapFailed(tag: String, logPath: String?) -> Bool {
        guard allowsCheck, let parsed = Release(tag: tag, page: nil) else { return false }
        if let version = build.version, !version.isOlder(than: parsed.version) { return false }
        let release = settings.latest?.tag == tag ? settings.latest! : parsed
        phase = .failed(release, UpdateFailure(message: Self.swapFailureMessage, logPath: logPath))
        settings.failedTag = tag
        return true
    }

    static let swapFailureMessage = "The new build couldn't replace the installed app, so this is still the old version."

    // MARK: What it shows

    /// The line above the footer; nil when there's nothing to say.
    public var banner: UpdateBanner? {
        switch phase {
        case let .installing(release, step):
            return UpdateBanner(style: .working, title: "Updating to \(release.tag)…", detail: step.text, page: release.page)
        case let .failed(release, failure):
            return UpdateBanner(style: .failed, title: "Couldn't update to \(release.tag)", detail: failure.message,
                                page: release.page, logPath: failure.logPath)
        case .idle:
            guard let available else { return nil }
            if canInstall {
                return UpdateBanner(style: .available, title: "Update to \(available.tag)", detail: "You have \(versionText)",
                                    page: available.page)
            }
            guard build.sourcePath != nil else {
                // A tarball: there's no checkout to fetch into.
                let clone = build.repository.map { "git clone --branch \(available.tag) https://github.com/\($0).git && cd \($0.name) && scripts/build.sh" }
                return UpdateBanner(style: .notifyOnly, title: "UsageBar \(available.tag) is available",
                                    detail: "This build wasn't made from a git checkout. To build the new version, run:",
                                    command: clone, page: available.page)
            }
            return UpdateBanner(
                style: .notifyOnly, title: "UsageBar \(available.tag) is available",
                detail: "The checkout this app was built from is gone. In your UsageBar checkout, run:",
                command: "git fetch --tags origin && git checkout --detach \(available.tag) && scripts/build.sh",
                page: available.page
            )
        }
    }

    /// The Updates section of the Providers menu.
    public func menu(clock: Clock) -> UpdateMenu {
        UpdateMenu(
            checkAutomatically: settings.checkAutomatically,
            installAutomatically: settings.installAutomatically,
            canInstallAutomatically: settings.checkAutomatically && canInstall,
            installDetail: canInstall ? nil : "Needs the source checkout it was built from",
            canCheckNow: canCheck && allowsCheck,
            status: status(clock: clock)
        )
    }

    private func status(clock: Clock) -> String {
        guard canCheck else { return "Not built by scripts/build.sh from a GitHub checkout" }
        if isChecking { return "Checking…" }
        if let checkError { return "Couldn't check: \(checkError)" }
        if let available { return "\(available.tag) is available" }
        guard let last = settings.lastCheck else { return "\(versionText) · not checked yet" }
        let checked = clock.updatedText(last).replacingOccurrences(of: "Updated", with: "checked")
        return "\(versionText) · up to date, \(checked)"
    }

    private var versionText: String {
        build.version?.text ?? "an untagged build"
    }
}

private extension Updater {
    /// Neither a check nor an update underway.
    var allowsCheck: Bool {
        if isChecking { return false }
        if case .installing = phase { return false }
        return true
    }
}

extension UpdateStep {
    /// What the popover says during the step.
    var text: String {
        switch self {
        case .checkingSource: "Checking the source folder"
        case .fetching: "Fetching the release"
        case .checkingOut: "Checking out the release"
        case .building: "Building, which takes a few minutes"
        case .relaunching: "Relaunching"
        }
    }
}
