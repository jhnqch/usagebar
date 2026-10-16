import Foundation

/// A command to run: an absolute executable, its arguments, the directory
/// to run it in, and environment variables to set on top of the app's.
public struct Command: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var environment: [String: String]

    public init(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }
}

/// How a command ended: its exit status (-1 when it couldn't start, e.g.
/// the directory is gone) and its output and errors together.
public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
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
    private let runner: any CommandRunner

    public init(sourcePath: String, repository: GitHubRepository, release: Release, stagingApp: String, runner: any CommandRunner) {
        self.sourcePath = sourcePath
        self.repository = repository
        self.release = release
        self.stagingApp = stagingApp
        self.runner = runner
    }

    /// Runs the update; nil when the app at `stagingApp` is built and ready.
    /// `progress` hears each step as it starts and `log` every command and
    /// its output. The failure's `logPath` is left for the caller to fill.
    public func run(progress: @Sendable (UpdateStep) async -> Void, log: @Sendable (String) -> Void) async -> UpdateFailure? {
        func fail(_ message: String) -> UpdateFailure {
            log("\n\(message)\n")
            return UpdateFailure(message: message, logPath: nil)
        }
        func git(_ arguments: String..., logsOutput: Bool = true) async -> CommandResult {
            await run(Command("/usr/bin/git", arguments, in: sourcePath, environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]),
                      logsOutput: logsOutput, log: log)
        }

        log("Updating to \(release.tag) in \(sourcePath)\n")
        await progress(.checkingSource)
        let topLevel = await git("rev-parse", "--show-toplevel")
        guard topLevel.status == 0, topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines) == sourcePath else {
            return fail("The source folder is missing or isn't a git checkout.")
        }
        // The URL may hold credentials: only the owner/name parsed from it is logged.
        let origin = await git("config", "--get", "remote.origin.url", logsOutput: false)
        guard origin.status == 0, let originRepository = GitHubRepository(remoteURL: origin.output) else {
            return fail("The source folder's origin isn't a GitHub repository.")
        }
        log("origin: \(originRepository)\n")
        guard originRepository.description.lowercased() == repository.description.lowercased() else {
            return fail("The source folder's origin is \(originRepository), but this app was built from \(repository).")
        }
        let status = await git("status", "--porcelain", "--untracked-files=no")
        guard status.status == 0, status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail("The source folder has uncommitted changes. Commit or stash them, then try again.")
        }
        let branch = await git("symbolic-ref", "--quiet", "--short", "HEAD")
        if branch.status == 0 {
            let name = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == "main" else { return fail("The source folder is on branch \(name), not main or a release tag.") }
        } else {
            let tag = await git("describe", "--tags", "--exact-match", "HEAD")
            guard tag.status == 0, Release(tag: tag.output.trimmingCharacters(in: .whitespacesAndNewlines), page: nil) != nil else {
                return fail("The source folder isn't on main or a release tag.")
            }
        }

        await progress(.fetching)
        guard await git("fetch", "--tags", "origin").status == 0 else {
            return fail("Couldn't fetch from origin. Check your connection and try again.")
        }
        // The tag came from a parsed version, so it can't pass for an option.
        let ref = "refs/tags/\(release.tag)"
        guard Release(tag: release.tag, page: nil) != nil, await git("rev-parse", "--verify", "--quiet", "\(ref)^{commit}").status == 0 else {
            return fail("origin has no tag \(release.tag).")
        }

        await progress(.checkingOut)
        // Git would otherwise overwrite an ignored local file the release tracks.
        guard await git("checkout", "--quiet", "--no-overwrite-ignore", "--detach", ref).status == 0 else {
            return fail("Couldn't check out \(release.tag). The log says why.")
        }

        await progress(.building)
        let build = Command("/bin/bash", ["scripts/build.sh"], in: sourcePath, environment: ["USAGEBAR_APP": stagingApp])
        guard await run(build, logsOutput: true, log: log).status == 0 else {
            return fail("The build failed.")
        }
        let built = Command("/bin/test", ["-x", stagingApp + "/Contents/MacOS/UsageBar"], in: sourcePath)
        guard await run(built, logsOutput: true, log: log).status == 0 else {
            return fail("The build didn't produce an app.")
        }
        log("\nBuilt \(release.tag) at \(stagingApp)\n")
        return nil
    }

    private func run(_ command: Command, logsOutput: Bool, log: @Sendable (String) -> Void) async -> CommandResult {
        let name = (command.executable as NSString).lastPathComponent
        log("\n$ \(([name] + command.arguments).joined(separator: " "))\n")
        let result = await runner.run(command)
        if logsOutput, !result.output.isEmpty { log(result.output.hasSuffix("\n") ? result.output : result.output + "\n") }
        if result.status != 0 { log("(exit \(result.status))\n") }
        return result
    }
}

/// Installs a built app and relaunches it, from a helper that outlives the
/// app: it waits for the running app's process to exit, copies the new
/// bundle beside the installed one, renames the installed one aside and the
/// copy into its place (putting the old one back if that fails), and opens
/// whichever is there. A failed copy leaves the installed app as it was.
///
/// The reopened app can't see the helper's exit status, so a failed swap
/// writes the release's tag to `statusFile` for the next launch to read
/// (`takeFailedTag`); a swap that works removes any earlier one.
public enum Relaunch {
    /// The status file's name in the support directory.
    public static let statusFileName = "update-failed"

    /// The helper: `/bin/sh` with a fixed script and the paths as
    /// arguments, never spliced into the script.
    public static func command(waitingFor pid: Int32, staged: String, app: String, tag: String, statusFile: String,
                               opener: String = "/usr/bin/open") -> Command {
        Command("/bin/sh", ["-c", script, "usagebar-relaunch", String(pid), staged, app, opener, tag, statusFile], in: "/")
    }

    /// The release whose swap failed, from the status file a relaunch
    /// helper left; nil when there's none or it doesn't hold a release tag.
    /// The file is removed, so a failure is reported once.
    public static func takeFailedTag(statusFile: String) -> String? {
        guard let data = FileManager.default.contents(atPath: statusFile) else { return nil }
        try? FileManager.default.removeItem(atPath: statusFile)
        let line = String(decoding: data.prefix(256), as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let tag = line.trimmingCharacters(in: .whitespaces)
        return Release(tag: tag, page: nil)?.tag
    }

    static let script = """
    pid="$1"; new="$2"; app="$3"; opener="$4"; tag="$5"; status_file="$6"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    next="$app.new"; old="$app.previous"
    rm -rf "$next" "$old"
    rm -f "$status_file"
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
    rm -rf "$next" "$old"
    if [ $status = 0 ]; then
      rm -rf "$new"
    else
      echo "Couldn't install $tag: the app at $app wasn't replaced."
      printf '%s\\n' "$tag" > "$status_file"
    fi
    "$opener" "$app"
    exit $status
    """
}
