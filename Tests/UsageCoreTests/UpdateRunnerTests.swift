import Foundation
import Synchronization
import Testing
import UsageCore

private let acme = GitHubRepository("acme/usagebar")!

private func release(_ tag: String) -> Release {
    Release(version: SemanticVersion(tag)!, tag: tag)
}

/// Collects what an update run reports.
private final class Recorder: Sendable {
    private let state = Mutex<(steps: [UpdateStep], log: String)>(([], ""))
    var steps: [UpdateStep] { state.withLock { $0.steps } }
    var log: String { state.withLock { $0.log } }

    func run(_ runner: UpdateRunner) async -> UpdateFailure? {
        await runner.run(progress: { step in self.state.withLock { $0.steps.append(step) } },
                         log: { text in self.state.withLock { $0.log += text } })
    }
}

/// A source checkout and the "GitHub" it fetches from: a bare repo standing
/// in for `https://github.com/acme/usagebar.git` (through git's `insteadOf`,
/// which `origin`'s recorded URL doesn't show). Tags v1.0.0 and v1.2.0 (whose
/// build fails) exist when it's cloned; v1.1.0 is tagged on the remote only
/// afterwards, so the update has to fetch it. Each tag's `scripts/build.sh`
/// is a stand-in that makes a tiny app at `$USAGEBAR_APP`.
private struct SourceCheckout {
    let root: TempDirectory
    var source: String { root.file("usagebar") }
    var remote: String { root.file("remote.git") }
    var staging: String { root.file("staging/UsageBar.app") }

    static let goodBuild = """
    #!/bin/bash
    set -euo pipefail
    echo "building $(git describe --tags)"
    mkdir -p "$USAGEBAR_APP/Contents/MacOS"
    printf '#!/bin/sh\\n' > "$USAGEBAR_APP/Contents/MacOS/UsageBar"
    chmod +x "$USAGEBAR_APP/Contents/MacOS/UsageBar"
    """

    init() throws {
        root = try TempDirectory()
        let work = root.file("work")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: work)
        try write(work, "scripts/build.sh", Self.goodBuild)
        try write(work, ".gitignore", "*.local\n")
        commit(work, "v1.0.0", tag: "v1.0.0")
        try write(work, "scripts/build.sh", "#!/bin/bash\necho 'error: compile error in Thing.swift'\nexit 1\n")
        commit(work, "broken", tag: "v1.2.0")
        try write(work, "scripts/build.sh", Self.goodBuild)
        try write(work, "README", "1.1\n")
        // v1.1.0 tracks a file matching .gitignore, where a user may already keep an ignored one.
        try write(work, "defaults.local", "shipped defaults\n")
        git("add", "-f", "defaults.local", in: work)
        commit(work, "v1.1.0", tag: nil)
        git("clone", "-q", "--bare", work, remote, in: root.path)
        git("clone", "-q", remote, source, in: root.path)
        git("remote", "set-url", "origin", "https://github.com/acme/usagebar.git", in: source)
        git("config", "url.\(remote).insteadOf", "https://github.com/acme/usagebar.git", in: source)
        git("checkout", "-q", "--detach", "v1.0.0", in: source)
        // v1.1.0 is published after the clone.
        git("tag", "v1.1.0", "main", in: remote)
    }

    private func write(_ directory: String, _ name: String, _ text: String) throws {
        let path = (directory as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func commit(_ directory: String, _ message: String, tag: String?) {
        git("add", "-A", in: directory)
        git("commit", "-q", "-m", message, in: directory)
        if let tag { git("tag", tag, in: directory) }
    }

    func runner(to tag: String, source: String? = nil) -> UpdateRunner {
        UpdateRunner(sourcePath: source ?? self.source, repository: acme, release: release(tag), stagingApp: staging,
                     runner: TestCommandRunner())
    }

    var head: String { git("describe", "--tags", "--always", in: source).output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

@Suite("Update runner against a temp git repo", .serialized)
struct UpdateRunnerGitTests {
    @Test("a clean checkout at a tag fetches, checks out and builds the release, keeping untracked files")
    func updates() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        try "my notes".write(toFile: checkout.source + "/notes.txt", atomically: true, encoding: .utf8)
        try "private".write(toFile: checkout.source + "/settings.local", atomically: true, encoding: .utf8)

        let recorder = Recorder()
        let failure = await recorder.run(checkout.runner(to: "v1.1.0"))

        #expect(failure == nil)
        #expect(checkout.head == "v1.1.0")
        #expect(recorder.steps == [.checkingSource, .fetching, .checkingOut, .building])
        #expect(FileManager.default.isExecutableFile(atPath: checkout.staging + "/Contents/MacOS/UsageBar"))
        #expect(try String(contentsOfFile: checkout.source + "/notes.txt", encoding: .utf8) == "my notes")
        #expect(try String(contentsOfFile: checkout.source + "/settings.local", encoding: .utf8) == "private")
        #expect(recorder.log.contains("$ git fetch --tags origin"))
        #expect(recorder.log.contains("building v1.1.0"))
    }

    @Test("an ignored local file the release would overwrite stops the checkout and is kept")
    func ignoredFileKept() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        try "mine".write(toFile: checkout.source + "/defaults.local", atomically: true, encoding: .utf8)
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0"))
        #expect(failure?.message == "Couldn't check out v1.1.0. The log says why.")
        #expect(checkout.head == "v1.0.0")
        #expect(try String(contentsOfFile: checkout.source + "/defaults.local", encoding: .utf8) == "mine")
    }

    @Test("credentials in origin's URL never reach the log")
    func credentialsNotLogged() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        let url = "https://someone:not-a-real-token@github.com/acme/usagebar.git"
        git("remote", "set-url", "origin", url, in: checkout.source)
        git("config", "url.\(checkout.remote).insteadOf", url, in: checkout.source)
        let recorder = Recorder()
        let failure = await recorder.run(checkout.runner(to: "v1.1.0"))
        #expect(failure == nil)
        #expect(!recorder.log.contains("not-a-real-token"))
        #expect(!recorder.log.contains("someone"))
        #expect(recorder.log.contains("acme/usagebar"))
    }

    @Test("a checkout on main updates too")
    func fromMain() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        git("checkout", "-q", "main", in: checkout.source)
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0"))
        #expect(failure == nil)
        #expect(checkout.head == "v1.1.0")
    }

    @Test("uncommitted changes are refused, and nothing moves")
    func dirty() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        try "edited".write(toFile: checkout.source + "/scripts/build.sh", atomically: true, encoding: .utf8)
        let recorder = Recorder()
        let failure = await recorder.run(checkout.runner(to: "v1.1.0"))
        #expect(failure?.message == "The source folder has uncommitted changes. Commit or stash them, then try again.")
        #expect(checkout.head == "v1.0.0")
        #expect(recorder.steps == [.checkingSource])
        #expect(git("rev-parse", "-q", "--verify", "refs/tags/v1.1.0", in: checkout.source).status != 0)  // not even fetched
    }

    @Test("a checkout on another branch is refused")
    func otherBranch() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        git("checkout", "-q", "-b", "my-feature", in: checkout.source)
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0"))
        #expect(failure?.message == "The source folder is on branch my-feature, not main or a release tag.")
        #expect(checkout.head == "v1.0.0")
    }

    @Test("a checkout detached away from a release tag is refused")
    func detachedOffTag() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        git("checkout", "-q", "--detach", "origin/main", in: checkout.source)  // untagged until v1.1.0 is fetched
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0"))
        #expect(failure?.message == "The source folder isn't on main or a release tag.")
    }

    @Test("a missing checkout is refused")
    func missing() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0", source: checkout.root.file("gone")))
        #expect(failure?.message == "The source folder is missing or isn't a git checkout.")
    }

    @Test("a folder inside another repo isn't the checkout")
    func notTheTopLevel() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0", source: checkout.source + "/scripts"))
        #expect(failure?.message == "The source folder is missing or isn't a git checkout.")
    }

    @Test("an origin that isn't on GitHub is refused", arguments: ["https://gitlab.com/acme/usagebar.git", "/srv/git/usagebar.git"])
    func notGitHub(origin: String) async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        git("remote", "set-url", "origin", origin, in: checkout.source)
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0"))
        #expect(failure?.message == "The source folder's origin isn't a GitHub repository.")
        #expect(checkout.head == "v1.0.0")
    }

    @Test("an origin on another GitHub repo is refused")
    func otherRepo() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        git("remote", "set-url", "origin", "git@github.com:someone/fork.git", in: checkout.source)
        let failure = await Recorder().run(checkout.runner(to: "v1.1.0"))
        #expect(failure?.message == "The source folder's origin is someone/fork, but this app was built from acme/usagebar.")
    }

    @Test("a failed build stops before anything is installed, and the log holds its output")
    func buildFails() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        let recorder = Recorder()
        let failure = await recorder.run(checkout.runner(to: "v1.2.0"))
        #expect(failure?.message == "The build failed.")
        #expect(!FileManager.default.fileExists(atPath: checkout.staging))
        #expect(recorder.log.contains("error: compile error in Thing.swift"))
        #expect(recorder.steps.last == .building)
    }

    @Test("a tag origin doesn't have is reported")
    func unknownTag() async throws {
        let checkout = try SourceCheckout()
        defer { checkout.root.remove() }
        let failure = await Recorder().run(checkout.runner(to: "v9.9.9"))
        #expect(failure?.message == "origin has no tag v9.9.9.")
        #expect(checkout.head == "v1.0.0")
    }
}

/// Answers each command from a script; records what ran.
private final class FakeCommands: CommandRunner {
    private let state: Mutex<(ran: [Command], answers: [String: CommandResult])>

    init(_ answers: [String: CommandResult]) {
        state = Mutex(([], answers))
    }

    var ran: [String] { state.withLock { $0.ran.map { ([$0.executable] + $0.arguments).joined(separator: " ") } } }
    var commands: [Command] { state.withLock { $0.ran } }

    func run(_ command: Command) async -> CommandResult {
        state.withLock { state in
            state.ran.append(command)
            let line = ([command.executable] + command.arguments).joined(separator: " ")
            return state.answers.first { line.hasSuffix($0.key) }?.value ?? CommandResult(status: 0, output: "")
        }
    }
}

@Suite("Update runner commands")
struct UpdateRunnerCommandTests {
    private static let clean: [String: CommandResult] = [
        "rev-parse --show-toplevel": CommandResult(status: 0, output: "/src/usagebar\n"),
        "config --get remote.origin.url": CommandResult(status: 0, output: "https://github.com/acme/usagebar.git\n"),
        "symbolic-ref --quiet --short HEAD": CommandResult(status: 0, output: "main\n"),
    ]

    @Test("the build gets the staging path and never sees the installed app; git never prompts")
    func build() async throws {
        let commands = FakeCommands(Self.clean)
        let runner = UpdateRunner(sourcePath: "/src/usagebar", repository: acme, release: release("v1.1.0"),
                                  stagingApp: "/support/Update/UsageBar.app", runner: commands)
        let failure = await Recorder().run(runner)
        #expect(failure == nil)
        #expect(commands.ran == [
            "/usr/bin/git rev-parse --show-toplevel",
            "/usr/bin/git config --get remote.origin.url",
            "/usr/bin/git status --porcelain --untracked-files=no",
            "/usr/bin/git symbolic-ref --quiet --short HEAD",
            "/usr/bin/git fetch --tags origin",
            "/usr/bin/git rev-parse --verify --quiet refs/tags/v1.1.0^{commit}",
            "/usr/bin/git checkout --quiet --no-overwrite-ignore --detach refs/tags/v1.1.0",
            "/bin/bash scripts/build.sh",
            "/bin/test -x /support/Update/UsageBar.app/Contents/MacOS/UsageBar",
        ])
        let build = try #require(commands.commands.first { $0.executable == "/bin/bash" })
        #expect(build.environment["USAGEBAR_APP"] == "/support/Update/UsageBar.app")
        #expect(commands.commands.filter { $0.executable == "/usr/bin/git" }.allSatisfy { $0.environment["GIT_TERMINAL_PROMPT"] == "0" })
        #expect(commands.commands.allSatisfy { $0.directory == "/src/usagebar" })
    }

    @Test("a build that leaves no app is a failure")
    func noApp() async {
        var answers = Self.clean
        answers["/bin/test -x /support/Update/UsageBar.app/Contents/MacOS/UsageBar"] = CommandResult(status: 1, output: "")
        let runner = UpdateRunner(sourcePath: "/src/usagebar", repository: acme, release: release("v1.1.0"),
                                  stagingApp: "/support/Update/UsageBar.app", runner: FakeCommands(answers))
        let failure = await Recorder().run(runner)
        #expect(failure?.message == "The build didn't produce an app.")
    }

    @Test("a failed fetch stops before checkout")
    func fetchFails() async {
        var answers = Self.clean
        answers["fetch --tags origin"] = CommandResult(status: 128, output: "fatal: unable to access")
        let commands = FakeCommands(answers)
        let runner = UpdateRunner(sourcePath: "/src/usagebar", repository: acme, release: release("v1.1.0"),
                                  stagingApp: "/support/Update/UsageBar.app", runner: commands)
        let failure = await Recorder().run(runner)
        #expect(failure?.message == "Couldn't fetch from origin. Check your connection and try again.")
        #expect(!commands.ran.contains { $0.contains("checkout") })
    }
}

@Suite("Relaunch", .serialized)
struct RelaunchTests {
    /// An "app" directory holding one file that says which build it is.
    private func makeApp(_ path: String, _ build: String) throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try build.write(toFile: path + "/Contents/build", atomically: true, encoding: .utf8)
    }

    /// The release tag the helper left in the status file, if any.
    private func failedTag(_ statusFile: String) -> String? {
        (try? String(contentsOfFile: statusFile, encoding: .utf8)).flatMap(Relaunch.failedTag(status:))
    }

    private func build(_ app: String) -> String? {
        try? String(contentsOfFile: app + "/Contents/build", encoding: .utf8)
    }

    @Test("the new app replaces the old only after the old process exits, then opens")
    func swapsAfterExit() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let app = dir.file("Applications/UsageBar.app"), staged = dir.file("staging/UsageBar.app")
        try makeApp(app, "old")
        try makeApp(staged, "new")
        try dir.write("open", "#!/bin/sh\necho \"$1\" > \"$(dirname \"$0\")/opened\"\n", executable: true)
        try dir.write("update-failed", "v1.0.5\n")  // from an earlier failed swap

        // Stands in for the running app.
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["30"]
        try running.run()

        let command = Relaunch.command(waitingFor: running.processIdentifier, staged: staged, app: app, tag: "v1.1.0",
                                       statusFile: dir.file("update-failed"), opener: dir.file("open"))
        let helper = Task.detached { shell(command.executable, command.arguments, in: command.directory) }
        try await Task.sleep(for: .milliseconds(700))
        #expect(build(app) == "old")
        #expect(!FileManager.default.fileExists(atPath: dir.file("opened")))

        running.terminate()
        let result = await helper.value
        #expect(result.status == 0, "\(result.output)")
        #expect(build(app) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged))
        #expect(!FileManager.default.fileExists(atPath: app + ".previous"))
        #expect(try String(contentsOfFile: dir.file("opened"), encoding: .utf8) == app + "\n")
        #expect(failedTag(dir.file("update-failed")) == nil)
    }

    @Test("a leftover from an earlier swap doesn't get in the way")
    func leftovers() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let app = dir.file("UsageBar.app"), staged = dir.file("staging/UsageBar.app")
        try makeApp(app, "old")
        try makeApp(staged, "new")
        try makeApp(app + ".new", "half-copied")
        try makeApp(app + ".previous", "older")
        try dir.write("open", "#!/bin/sh\nexit 0\n", executable: true)
        let command = Relaunch.command(waitingFor: 999_999, staged: staged, app: app, tag: "v1.1.0", statusFile: dir.file("update-failed"),
                                       opener: dir.file("open"))
        let result = shell(command.executable, command.arguments, in: command.directory)
        #expect(result.status == 0, "\(result.output)")
        #expect(build(app) == "new")
        #expect(!FileManager.default.fileExists(atPath: app + ".new"))
        #expect(!FileManager.default.fileExists(atPath: app + ".previous"))
    }

    @Test("without a staged app the old one stays and reopens")
    func keepsOld() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let app = dir.file("UsageBar.app")
        try makeApp(app, "old")
        try dir.write("open", "#!/bin/sh\necho \"$1\" > \"$(dirname \"$0\")/opened\"\n", executable: true)
        let command = Relaunch.command(waitingFor: 999_999, staged: dir.file("missing/UsageBar.app"), app: app, tag: "v1.1.0",
                                       statusFile: dir.file("update-failed"), opener: dir.file("open"))
        let result = shell(command.executable, command.arguments, in: command.directory)
        #expect(result.status != 0)
        #expect(build(app) == "old")
        #expect(FileManager.default.fileExists(atPath: dir.file("opened")))
        #expect(failedTag(dir.file("update-failed")) == "v1.1.0")
    }

    @Test("a swap that can't write beside the app keeps the old one and leaves the failed tag for the next launch")
    func swapFails() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let folder = dir.file("Applications"), app = folder + "/UsageBar.app", staged = dir.file("staging/UsageBar.app")
        try makeApp(app, "old")
        try makeApp(staged, "new")
        try dir.write("open", "#!/bin/sh\necho \"$1\" > \"$(dirname \"$0\")/opened\"\n", executable: true)
        // Like a full disk: nothing can be created beside the installed app.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        let command = Relaunch.command(waitingFor: 999_999, staged: staged, app: app, tag: "v1.1.0", statusFile: dir.file("update-failed"),
                                       opener: dir.file("open"))
        let result = shell(command.executable, command.arguments, in: command.directory)
        #expect(result.status != 0)
        #expect(result.output.contains("Couldn't install v1.1.0"), "\(result.output)")
        #expect(build(app) == "old")
        #expect(FileManager.default.fileExists(atPath: staged))
        #expect(try String(contentsOfFile: dir.file("opened"), encoding: .utf8) == app + "\n")
        #expect(failedTag(dir.file("update-failed")) == "v1.1.0")
    }

    @Test("a status file that doesn't hold a release tag reads as none", arguments: ["", "garbage\n", "--force\n", "v1.1\n", "v1.2.0-beta\n"])
    func unreadableStatus(text: String) {
        #expect(Relaunch.failedTag(status: text) == nil)
    }

    @Test("the status file's tag may have surrounding blanks or no newline", arguments: ["v1.1.0", "v1.1.0\n", "  v1.1.0  \n\nmore\n"])
    func statusTag(text: String) {
        #expect(Relaunch.failedTag(status: text) == "v1.1.0")
    }
}
