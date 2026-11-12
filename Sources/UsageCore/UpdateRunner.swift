import Foundation

/// A command to run: an absolute executable, its arguments, the directory
/// to run it in, environment variables to set on top of the app's, and how
/// long it may take (nil: as long as it takes).
public struct Command: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var environment: [String: String]
    public var timeout: TimeInterval?

    public init(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String] = [:],
                timeout: TimeInterval? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
    }
}

/// How a command ended: its exit status (-1 when it couldn't start, e.g.
/// the directory is gone), its output and errors together, and whether it
/// was stopped at its deadline.
public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var timedOut: Bool

    public init(status: Int32, output: String, timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }
}

/// Runs commands to the end. The app's runs real processes; tests use a
/// fake or a temp git repo.
public protocol CommandRunner: Sendable {
    func run(_ command: Command) async -> CommandResult
}

/// The one-click update, up to a built app waiting to be installed:
///
/// 1. Check the source checkout: it's a git work tree at `sourcePath`, its
///    `origin` is the GitHub repo the app was built from, it has no
///    uncommitted changes to tracked files, and it's on `main` or detached
///    at a release tag. Anything else is refused and nothing moves.
/// 2. `git fetch --tags origin`.
/// 3. `git checkout --detach` the release's tag.
/// 4. `scripts/build.sh` with `USAGEBAR_APP` set to `stagingApp`, never the
///    installed app: that's replaced by `Relaunch` once the app has quit.
///
/// Untracked and ignored files are never touched: there's no `git clean`,
/// and checkout itself refuses to overwrite an untracked file.
public struct UpdateRunner: Sendable {
    public var sourcePath: String
    public var repository: GitHubRepository
    public var release: Release
    public var stagingApp: String
    public var deadlines: Deadlines
    private let runner: any CommandRunner

    /// How long each command may run before it's stopped and the update
    /// fails: a stalled fetch or build would otherwise block every check
    /// and update until the app quits.
    public struct Deadlines: Equatable, Sendable {
        /// `git fetch`, over the network.
        public var fetch: TimeInterval
        /// `scripts/build.sh`: a release build from scratch.
        public var build: TimeInterval
        /// Every other command, all local.
        public var local: TimeInterval

        public init(fetch: TimeInterval = 5 * 60, build: TimeInterval = 30 * 60, local: TimeInterval = 60) {
            self.fetch = fetch
            self.build = build
            self.local = local
        }
    }

    public init(sourcePath: String, repository: GitHubRepository, release: Release, stagingApp: String, runner: any CommandRunner,
                deadlines: Deadlines = Deadlines()) {
        self.sourcePath = sourcePath
        self.repository = repository
        self.release = release
        self.stagingApp = stagingApp
        self.deadlines = deadlines
        self.runner = runner
    }

    /// Runs the update; nil when the app at `stagingApp` is built and ready.
    /// `progress` hears each step as it starts and `log` every command and
    /// its output. The failure's `logPath` is left for the caller to fill.
    /// A command stopped at its deadline fails the update there.
    public func run(progress: @Sendable (UpdateStep) async -> Void, log: @Sendable (String) -> Void) async -> UpdateFailure? {
        do {
            try await steps(progress: progress, log: log)
            return nil
        } catch {
            log("\n\(error.message)\n")
            return error
        }
    }

    private func steps(progress: @Sendable (UpdateStep) async -> Void, log: @Sendable (String) -> Void) async throws(UpdateFailure) {
        func fail(_ message: String) -> UpdateFailure {
            UpdateFailure(message: message, logPath: nil)
        }
        func git(_ arguments: String..., logsOutput: Bool = true, timeout: TimeInterval? = nil,
                 name: String? = nil) async throws(UpdateFailure) -> CommandResult {
            let command = Command("/usr/bin/git", arguments, in: sourcePath, environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
                                  timeout: timeout ?? deadlines.local)
            return try await run(command, name: name ?? "git \(arguments[0])", logsOutput: logsOutput, log: log)
        }

        log("Updating to \(release.tag) in \(sourcePath)\n")
        await progress(.checkingSource)
        let topLevel = try await git("rev-parse", "--show-toplevel")
        guard topLevel.status == 0, topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines) == sourcePath else {
            throw fail("The source folder is missing or isn't a git checkout.")
        }
        // The URL may hold credentials: only the owner/name parsed from it is logged.
        let origin = try await git("config", "--get", "remote.origin.url", logsOutput: false)
        guard origin.status == 0, let originRepository = GitHubRepository(remoteURL: origin.output) else {
            throw fail("The source folder's origin isn't a GitHub repository.")
        }
        log("origin: \(originRepository)\n")
        guard originRepository.description.lowercased() == repository.description.lowercased() else {
            throw fail("The source folder's origin is \(originRepository), but this app was built from \(repository).")
        }
        let status = try await git("status", "--porcelain", "--untracked-files=no")
        guard status.status == 0, status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("The source folder has uncommitted changes. Commit or stash them, then try again.")
        }
        let branch = try await git("symbolic-ref", "--quiet", "--short", "HEAD")
        if branch.status == 0 {
            let name = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == "main" else { throw fail("The source folder is on branch \(name), not main or a release tag.") }
        } else {
            let tag = try await git("describe", "--tags", "--exact-match", "HEAD")
            guard tag.status == 0, Release(tag: tag.output.trimmingCharacters(in: .whitespacesAndNewlines), page: nil) != nil else {
                throw fail("The source folder isn't on main or a release tag.")
            }
        }

        await progress(.fetching)
        let fetch = try await git("fetch", "--tags", "origin", timeout: deadlines.fetch, name: "Fetching from origin")
        guard fetch.status == 0 else {
            // Only a failure to reach origin is worth retrying as it is; a
            // rejected tag or a refused login fails the same way every time.
            throw fail(Self.isUnreachable(fetch.output) ? "Couldn't reach origin. Check your connection and try again."
                                                        : "Couldn't fetch from origin. The log says why.")
        }
        // The tag came from a parsed version, so it can't pass for an option.
        let ref = "refs/tags/\(release.tag)"
        guard Release(tag: release.tag, page: nil) != nil, try await git("rev-parse", "--verify", "--quiet", "\(ref)^{commit}").status == 0 else {
            throw fail("origin has no tag \(release.tag).")
        }

        await progress(.checkingOut)
        // Git would otherwise overwrite an ignored local file the release tracks.
        guard try await git("checkout", "--quiet", "--no-overwrite-ignore", "--detach", ref).status == 0 else {
            throw fail("Couldn't check out \(release.tag). The log says why.")
        }

        await progress(.building)
        let build = Command("/bin/bash", ["scripts/build.sh"], in: sourcePath, environment: ["USAGEBAR_APP": stagingApp],
                            timeout: deadlines.build)
        guard try await run(build, name: "The build", logsOutput: true, log: log).status == 0 else {
            throw fail("The build failed.")
        }
        let built = Command("/bin/test", ["-x", stagingApp + "/Contents/MacOS/UsageBar"], in: sourcePath, timeout: deadlines.local)
        guard try await run(built, name: "Checking the build", logsOutput: true, log: log).status == 0 else {
            throw fail("The build didn't produce an app.")
        }
        log("\nBuilt \(release.tag) at \(stagingApp)\n")
    }

    /// Runs and logs `command`; one stopped at its deadline fails the
    /// update with `name`: "The build took longer than 30 minutes, so it
    /// was stopped."
    private func run(_ command: Command, name: String, logsOutput: Bool,
                     log: @Sendable (String) -> Void) async throws(UpdateFailure) -> CommandResult {
        let executable = (command.executable as NSString).lastPathComponent
        log("\n$ \(([executable] + command.arguments).joined(separator: " "))\n")
        let result = await runner.run(command)
        if logsOutput, !result.output.isEmpty { log(result.output.hasSuffix("\n") ? result.output : result.output + "\n") }
        if result.timedOut, let timeout = command.timeout {
            let limit = Self.durationText(timeout)
            log("(stopped after \(limit))\n")
            throw UpdateFailure(message: "\(name) took longer than \(limit), so it was stopped.", logPath: nil)
        }
        if result.status != 0 { log("(exit \(result.status))\n") }
        return result
    }

    /// git's and ssh's words for not reaching the server at all.
    private static func isUnreachable(_ output: String) -> Bool {
        let signs = ["could not resolve host", "could not resolve hostname", "failed to connect", "couldn't connect to server",
                     "connection timed out", "operation timed out", "connection refused", "network is unreachable",
                     "no route to host", "connection reset"]
        let text = output.lowercased()
        return signs.contains { text.contains($0) }
    }

    /// "1 second", "45 seconds", "1 minute", "30 minutes".
    static func durationText(_ interval: TimeInterval) -> String {
        if interval >= 60, interval.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(interval / 60)
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let seconds = Int(interval.rounded())
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}

/// Installs a built app and relaunches it, from a helper that outlives the
/// app: it waits for the running app's process to exit, copies the new
/// bundle beside the installed one, renames the installed one aside and the
/// copy into its place (putting the old one back if that fails), and opens
/// whichever is there. A failed copy leaves the installed app as it was;
/// when the old one can't be put back either, it's kept where it was set
/// aside (`UsageBar.previous.app` beside it) and opened from there.
///
/// The reopened app can't see the helper's exit status, so the helper
/// writes the release's tag to `statusFile` before the copy and removes it
/// once the swap works; a tag left there is a failed swap, for the next
/// launch to read (`failedTag(status:)`).
public enum Relaunch {
    /// The status file's name in the support directory.
    public static let statusFileName = "update-failed"

    /// The helper: `/bin/sh` with a fixed script and the paths as
    /// arguments, never spliced into the script.
    public static func command(waitingFor pid: Int32, staged: String, app: String, tag: String, statusFile: String,
                               opener: String = "/usr/bin/open") -> Command {
        Command("/bin/sh", ["-c", script, "usagebar-relaunch", String(pid), staged, app, opener, tag, statusFile], in: "/")
    }

    /// The release whose swap failed, from the text of the status file a
    /// relaunch helper left; nil when it doesn't hold a release tag. The
    /// app reads the file and removes it, so a failure is reported once.
    public static func failedTag(status: String) -> String? {
        let line = status.prefix(256).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Release(tag: line.trimmingCharacters(in: .whitespaces), page: nil)?.tag
    }

    static let script = """
    pid="$1"; new="$2"; app="$3"; opener="$4"; tag="$5"; status_file="$6"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    # The set-aside copy keeps a .app name: should it end up the only copy
    # left, it still opens as an app and can update itself again.
    next="$app.new"; old="${app%.app}.previous.app"
    # "$app.previous" is where the helper in v1.0.1 and earlier set it aside.
    rm -rf "$next" "$old" "$app.previous"
    # Written first and removed only once the swap works: a disk too full
    # to copy the app may have no room for it afterwards.
    printf '%s\\n' "$tag" > "$status_file"
    status=1
    # Copy beside the installed app first (staging may be on another
    # volume), so the swap itself is two renames on one volume.
    if [ -d "$new" ] && ditto "$new" "$next"; then
      if [ ! -e "$app" ] || mv "$app" "$old"; then
        if mv "$next" "$app"; then
          status=0
        elif [ -e "$old" ]; then
          rm -rf "$app"
          mv "$old" "$app"
        fi
      fi
    fi
    rm -rf "$next"
    if [ $status = 0 ]; then
      rm -rf "$old" "$new"
      rm -f "$status_file"
    elif [ -e "$app" ]; then
      rm -rf "$old"
      echo "Couldn't install $tag: the app at $app wasn't replaced."
    elif [ -e "$old" ]; then
      # Neither the new build nor the old one could be put in place: the
      # set-aside copy is the only one left, so it stays and opens.
      echo "Couldn't install $tag, or put the previous app back: it's at $old."
      app="$old"
    else
      echo "Couldn't install $tag: there's no app at $app."
    fi
    "$opener" "$app"
    exit $status
    """
}
