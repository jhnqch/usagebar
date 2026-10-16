import AppKit
import Observation
import OSLog
import Synchronization
import UsageCore

/// Updates from source: runs `Updater`'s checks against GitHub and its
/// one-click update in the recorded checkout, keeps its settings in
/// `UserDefaults`, and relaunches into the new build. All state changes
/// happen on the main actor; the update's commands run off it.
@MainActor
@Observable
final class UpdateController {
    private(set) var updater: Updater
    @ObservationIgnored private let defaults: any KeyValueStore
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "updates")

    /// The update's log, rewritten by each update.
    static let logURL = supportDirectory.appending(path: "update.log")
    /// Where the update builds the new app; the installed one is replaced
    /// only after the old process exits (`Relaunch`).
    static let stagingApp = supportDirectory.appending(path: "Update/UsageBar.app")
    private static let supportDirectory = ClaudeStatusLine.supportDirectory(
        environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser
    )

    init(
        build: BuildInfo = BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]),
        defaults: any KeyValueStore = UserDefaults.standard,
        transport: any HTTPTransport = URLSessionTransport(),
        runner: any CommandRunner = ProcessCommandRunner()
    ) {
        self.defaults = defaults
        self.transport = transport
        self.runner = runner
        updater = Updater(build: build, settings: UpdateSettings(loadingFrom: defaults), sourceExists: Self.sourceExists(build.sourcePath))
    }

    var banner: UpdateBanner? { updater.banner }

    func menu() -> UpdateMenu {
        updater.menu(clock: Clock(now: Date(), timeZone: .current))
    }

    /// Looks again for the source checkout and checks if a check is due:
    /// on the app's ticker and when the popover opens.
    func tick() {
        let exists = Self.sourceExists(updater.build.sourcePath)
        if exists != updater.sourceExists { updater.sourceExists = exists }
        if updater.isCheckDue(at: Date()) { check() }
    }

    /// "Check now" in the Updates menu.
    func checkNow() {
        check()
    }

    func setCheckAutomatically(_ isOn: Bool) {
        updater.settings.checkAutomatically = isOn
        updater.settings.save(to: defaults)
        tick()
    }

    func setInstallAutomatically(_ isOn: Bool) {
        updater.settings.installAutomatically = isOn
        updater.settings.save(to: defaults)
    }

    private func check() {
        guard let repository = updater.build.repository, updater.startCheck(at: Date()) else { return }
        let request = GitHubRelease.request(for: repository, userAgent: "UsageBar/\(updater.build.version?.base.description ?? "dev")")
        let transport = transport
        Task {
            let outcome = await transport.send(request)
            let result = GitHubRelease.check(outcome)
            log.info("update check: \(String(describing: result), privacy: .public)")
            let action = updater.finishCheck(result, at: Date())
            updater.settings.save(to: defaults)
            if action == .install { install() }
        }
    }

    /// The one-click update: fetch, check out and build the release in the
    /// source checkout, then quit and let `Relaunch` install and reopen it.
    /// A refusal or failure leaves the running app as it is.
    func install() {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", let source = updater.build.sourcePath, let repository = updater.build.repository,
              let release = updater.startInstall()
        else { return }
        let logPath = (Self.logURL.path as NSString).abbreviatingWithTildeInPath
        let logFile = LogFile(url: Self.logURL)
        let update = UpdateRunner(sourcePath: source, repository: repository, release: release,
                                  stagingApp: Self.stagingApp.path, runner: runner)
        log.info("updating to \(release.tag, privacy: .public)")
        Task {
            let failure = await update.run(
                progress: { step in await MainActor.run { self.updater.advance(step) } },
                log: { logFile.append($0) }
            )
            if var failure {
                failure.logPath = logPath
                log.error("update failed: \(failure.message, privacy: .public)")
                updater.fail(failure)
                return
            }
            updater.advance(.relaunching)
            relaunch(app: app, logFile: logFile)
        }
    }

    /// Starts the helper that waits for this process to exit, swaps the
    /// new build into place and opens it; then quits.
    private func relaunch(app: URL, logFile: LogFile) {
        let command = Relaunch.command(waitingFor: ProcessInfo.processInfo.processIdentifier, staged: Self.stagingApp.path, app: app.path)
        logFile.append("\nRelaunching \(app.path)\n")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command.executable)
        helper.arguments = command.arguments
        helper.currentDirectoryURL = URL(fileURLWithPath: command.directory)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = logFile.handle ?? FileHandle.nullDevice
        helper.standardError = logFile.handle ?? FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            updater.fail(UpdateFailure(message: "Couldn't start the relaunch: \(error.localizedDescription)",
                                       logPath: (Self.logURL.path as NSString).abbreviatingWithTildeInPath))
            return
        }
        NSApp.terminate(nil)
    }

    func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.logURL])
    }

    func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Only a github.com page reaches here (`GitHubRelease`).
    func openPage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    var actions: UpdateActions {
        UpdateActions(install: { [weak self] in self?.install() }, showLog: { [weak self] in self?.showLog() },
                      copy: { [weak self] in self?.copy($0) }, openPage: { [weak self] in self?.openPage($0) })
    }

    /// Whether the recorded checkout is still a checkout with the build script.
    private static func sourceExists(_ path: String?) -> Bool {
        guard let path else { return false }
        let files = FileManager.default
        return files.fileExists(atPath: path + "/.git") && files.isExecutableFile(atPath: path + "/scripts/build.sh")
    }
}

/// The update log: truncated when an update starts, appended to as it runs.
final class LogFile: Sendable {
    let handle: FileHandle?
    private let lock = Mutex(())

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func append(_ text: String) {
        lock.withLock { _ in try? handle?.write(contentsOf: Data(text.utf8)) }
    }
}

/// Runs a command as a child process with the app's environment plus the
/// command's, and the system's tool directories on PATH (an app launched
/// from Finder gets a bare one). Waits on a dispatch thread, not the
/// concurrency pool, since a build takes minutes.
struct ProcessCommandRunner: CommandRunner {
    func run(_ command: Command) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments
                process.currentDirectoryURL = URL(fileURLWithPath: command.directory)
                var environment = ProcessInfo.processInfo.environment
                let path = environment["PATH"].map { $0 + ":" } ?? ""
                environment["PATH"] = path + "/usr/bin:/bin:/usr/sbin:/sbin"
                process.environment = environment.merging(command.environment) { $1 }
                let pipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
