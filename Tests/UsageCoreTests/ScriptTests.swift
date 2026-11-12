import Foundation
import Testing
import UsageCore

/// Copies one of the repo's scripts into `directory/scripts/`.
private func install(_ script: String, in directory: TempDirectory, at subpath: String = "") throws {
    let source = try String(contentsOfFile: "\(repoRoot)/scripts/\(script)", encoding: .utf8)
    try directory.write((subpath.isEmpty ? "" : subpath + "/") + "scripts/\(script)", source, executable: true)
}

/// `scripts/build-info.sh`'s `key=value` lines as a dictionary.
private func buildInfo(in directory: String) -> [String: String] {
    let result = shell("/bin/bash", ["scripts/build-info.sh"], in: directory)
    #expect(result.status == 0, "\(result.output)")
    return result.output.split(separator: "\n").reduce(into: [:]) { info, line in
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 { info[String(parts[0])] = String(parts[1]) }
    }
}

@Suite("Build info script", .serialized)
struct BuildInfoScriptTests {
    /// A checkout of `origin` with one commit, tagged when `tag` is given.
    private func checkout(origin: String?, tag: String? = "v1.2.0") throws -> TempDirectory {
        let dir = try TempDirectory()
        try install("build-info.sh", in: dir)
        git("init", "-q", "-b", "main", in: dir.path)
        git("add", "-A", in: dir.path)
        git("commit", "-q", "-m", "first", in: dir.path)
        if let tag { git("tag", tag, in: dir.path) }
        if let origin { git("remote", "add", "origin", origin, in: dir.path) }
        return dir
    }

    @Test("a checkout at a tag records the tag, its GitHub repo and its path")
    func atTag() throws {
        let dir = try checkout(origin: "https://github.com/acme/usagebar.git")
        defer { dir.remove() }
        #expect(buildInfo(in: dir.path) == ["version": "v1.2.0", "repository": "acme/usagebar", "source": dir.path])
    }

    @Test("commits past a tag are part of the version")
    func pastTag() throws {
        let dir = try checkout(origin: "git@github.com:acme/usagebar.git")
        defer { dir.remove() }
        try dir.write("README", "more")
        git("add", "-A", in: dir.path)
        git("commit", "-q", "-m", "second", in: dir.path)
        let info = buildInfo(in: dir.path)
        #expect(info["version"]?.hasPrefix("v1.2.0-1-g") == true)
        #expect(info["repository"] == "acme/usagebar")
    }

    @Test("credentials in the origin URL are never recorded", arguments: [
        "https://someone:not-a-real-token@github.com/acme/usagebar.git", "ssh://git@github.com/acme/usagebar", "https://GitHub.com/acme/usagebar/",
    ])
    func origins(origin: String) throws {
        let dir = try checkout(origin: origin)
        defer { dir.remove() }
        let result = shell("/bin/bash", ["scripts/build-info.sh"], in: dir.path)
        #expect(result.output.contains("repository=acme/usagebar\n"))
        #expect(!result.output.contains("not-a-real-token"))
        #expect(!result.output.contains("someone"))
    }

    @Test("an origin off GitHub, or none, records no repository", arguments: ["https://gitlab.com/acme/usagebar.git", "/srv/git/usagebar.git", nil])
    func notGitHub(origin: String?) throws {
        let dir = try checkout(origin: origin)
        defer { dir.remove() }
        let info = buildInfo(in: dir.path)
        #expect(info["repository"] == "")
        #expect(info["source"] == dir.path)
    }

    @Test("a checkout with no tags records no version")
    func noTags() throws {
        let dir = try checkout(origin: "https://github.com/acme/usagebar.git", tag: nil)
        defer { dir.remove() }
        #expect(buildInfo(in: dir.path)["version"] == "")
    }

    @Test("a tarball records no source, the upstream repo and the version in its folder name")
    func tarball() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try install("build-info.sh", in: dir, at: "usagebar-1.3.0")
        #expect(buildInfo(in: dir.file("usagebar-1.3.0")) == ["version": "v1.3.0", "repository": "jhnqch/usagebar", "source": ""])

        try install("build-info.sh", in: dir, at: "usagebar-main")
        #expect(buildInfo(in: dir.file("usagebar-main"))["version"] == "")
    }

    @Test("a tarball unpacked inside another git repo isn't a checkout")
    func insideAnotherRepo() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        git("init", "-q", in: dir.path)
        try install("build-info.sh", in: dir, at: "usagebar-1.3.0")
        #expect(buildInfo(in: dir.file("usagebar-1.3.0"))["source"] == "")
    }
}

@Suite("Release script", .serialized)
struct ReleaseScriptTests {
    /// A clone of a bare "origin" on main, with `release.sh` committed and a
    /// fake `gh` on PATH that writes its arguments to `gh-args`.
    private struct Repo {
        let root: TempDirectory
        var work: String { root.file("work") }
        var origin: String { root.file("origin.git") }

        init() throws {
            root = try TempDirectory()
            git("init", "-q", "--bare", "-b", "main", origin, in: root.path)
            git("clone", "-q", origin, work, in: root.path)
            git("checkout", "-q", "-b", "main", in: work)
            // origin reads as GitHub; git takes it to the local bare repo.
            git("remote", "set-url", "origin", "https://github.com/acme/usagebar.git", in: work)
            git("config", "url.\(origin).insteadOf", "https://github.com/acme/usagebar.git", in: work)
            for script in ["release.sh", "build-info.sh"] {
                let text = try String(contentsOfFile: "\(repoRoot)/scripts/\(script)", encoding: .utf8)
                try root.write("work/scripts/\(script)", text, executable: true)
            }
            try root.write("work/.gitignore", "*.local\n")
            git("add", "-A", in: work)
            git("commit", "-q", "-m", "first", in: work)
            git("push", "-q", "origin", "main", in: work)
            // `gh`: signed in unless `gh-signed-out` exists; `release create`
            // fails while `gh-fails` exists, else records its arguments in
            // `gh-args` and the release as made; `release view` finds it.
            try root.write("bin/gh", #"""
                #!/bin/sh
                state="$(dirname "$0")/.."
                case "$1 $2" in
                  "auth status") [ ! -e "$state/gh-signed-out" ] || { echo "You are not logged into any GitHub hosts." >&2; exit 1; } ;;
                  "release view") [ -e "$state/gh-released" ] || { echo "release not found" >&2; exit 1; } ;;
                  "release create")
                    [ ! -e "$state/gh-fails" ] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
                    printf '%s\n' "$@" > "$state/gh-args"
                    touch "$state/gh-released" ;;
                  *) echo "unexpected gh $*" >&2; exit 2 ;;
                esac
                """#, executable: true)
        }

        /// Creates (or removes) one of the fake `gh`'s state files.
        func gh(_ state: String, _ on: Bool = true) throws {
            if on { try root.write(state, "") } else { try FileManager.default.removeItem(atPath: root.file(state)) }
        }

        /// What `tag` names on origin (a tag object for an annotated tag).
        func originTag(_ tag: String) -> String {
            git("rev-parse", "-q", "--verify", "refs/tags/\(tag)", in: origin).output
        }

        func release(_ arguments: String...) -> CommandResult {
            shell("/bin/bash", ["scripts/release.sh"] + arguments, in: work,
                  environment: ["PATH": root.file("bin") + ":/usr/bin:/bin"])
        }

        var ghArguments: [String]? {
            (try? String(contentsOfFile: root.file("gh-args"), encoding: .utf8)).map { $0.split(separator: "\n").map(String.init) }
        }

        func hasTag(_ tag: String, in directory: String) -> Bool {
            git("rev-parse", "-q", "--verify", "refs/tags/\(tag)", in: directory).status == 0
        }
    }

    @Test("a clean, pushed main gets an annotated tag on origin and a GitHub Release with generated notes")
    func releases() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        try repo.root.write("work/notes.local", "untracked files don't count")
        let result = repo.release("v1.2.3")
        #expect(result.status == 0, "\(result.output)")
        #expect(repo.hasTag("v1.2.3", in: repo.origin))
        #expect(git("cat-file", "-t", "v1.2.3", in: repo.work).output == "tag\n")
        #expect(repo.ghArguments == ["release", "create", "v1.2.3", "--repo", "acme/usagebar", "--verify-tag", "--generate-notes",
                                     "--title", "UsageBar v1.2.3"])
    }

    @Test("an origin off GitHub is refused before anything is tagged")
    func notGitHub() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        git("remote", "set-url", "origin", repo.origin, in: repo.work)
        let result = repo.release("v1.2.3")
        #expect(result.status != 0)
        #expect(result.output.contains("origin isn't a GitHub repository"))
        #expect(!repo.hasTag("v1.2.3", in: repo.work))
    }

    @Test("a tag that isn't vX.Y.Z is refused", arguments: ["1.2.3", "v1.2", "v1.2.3-rc.1", "v01.2.3", "latest", ""])
    func notSemver(tag: String) throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        let result = repo.release(tag)
        #expect(result.status != 0)
        #expect(result.output.contains("vX.Y.Z"))
        #expect(repo.ghArguments == nil)
    }

    @Test("uncommitted changes are refused")
    func dirty() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        try repo.root.write("work/.gitignore", "changed\n")
        let result = repo.release("v1.2.3")
        #expect(result.status != 0)
        #expect(result.output.contains("uncommitted changes"))
        #expect(!repo.hasTag("v1.2.3", in: repo.work))
    }

    @Test("a tag that already exists at another commit, here or on origin, is refused")
    func exists() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        git("tag", "v1.0.0", in: repo.work)
        try repo.root.write("work/README", "second")
        git("add", "-A", in: repo.work)
        git("commit", "-q", "-m", "second", in: repo.work)
        git("push", "-q", "origin", "main", in: repo.work)
        #expect(repo.release("v1.0.0").output.contains("v1.0.0 already exists at another commit"))
        git("tag", "v1.1.0", "main~1", in: repo.origin)
        let result = repo.release("v1.1.0")
        #expect(result.status != 0)
        #expect(result.output.contains("v1.1.0 already exists at another commit"))
        #expect(repo.ghArguments == nil)
    }

    @Test("gh signed out is refused before anything is tagged")
    func signedOut() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        try repo.gh("gh-signed-out")
        let result = repo.release("v1.2.3")
        #expect(result.status != 0)
        #expect(result.output.contains("gh auth login"), "\(result.output)")
        #expect(!repo.hasTag("v1.2.3", in: repo.work))
        #expect(!repo.hasTag("v1.2.3", in: repo.origin))
    }

    @Test("a rerun after the release step failed creates the release from the tag already pushed, without retagging")
    func rerun() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        try repo.gh("gh-fails")
        #expect(repo.release("v1.2.3").status != 0)
        let pushed = repo.originTag("v1.2.3")
        #expect(!pushed.isEmpty)

        try repo.gh("gh-fails", false)
        let result = repo.release("v1.2.3")
        #expect(result.status == 0, "\(result.output)")
        #expect(repo.originTag("v1.2.3") == pushed)
        #expect(repo.ghArguments?.prefix(3) == ["release", "create", "v1.2.3"])
    }

    @Test("a rerun after the tag push failed pushes the same tag and releases")
    func rerunUnpushed() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        git("tag", "--annotate", "v1.2.3", "--message", "UsageBar v1.2.3", in: repo.work)
        let made = git("rev-parse", "refs/tags/v1.2.3", in: repo.work).output
        let result = repo.release("v1.2.3")
        #expect(result.status == 0, "\(result.output)")
        #expect(repo.originTag("v1.2.3") == made)
        #expect(repo.ghArguments?.prefix(3) == ["release", "create", "v1.2.3"])
    }

    @Test("a tag that's already released is refused")
    func alreadyReleased() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        #expect(repo.release("v1.2.3").status == 0)
        try FileManager.default.removeItem(atPath: repo.root.file("gh-args"))
        let result = repo.release("v1.2.3")
        #expect(result.status != 0)
        #expect(result.output.contains("v1.2.3 is already released"), "\(result.output)")
        #expect(repo.ghArguments == nil)
    }

    @Test("only main, pushed as it is, can be released")
    func onlyPushedMain() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        git("checkout", "-q", "-b", "feature", in: repo.work)
        #expect(repo.release("v1.2.3").output.contains("main"))
        git("checkout", "-q", "main", in: repo.work)
        try repo.root.write("work/README", "unpushed")
        git("add", "-A", in: repo.work)
        git("commit", "-q", "-m", "unpushed", in: repo.work)
        let result = repo.release("v1.2.3")
        #expect(result.status != 0)
        #expect(result.output.contains("origin/main"))
        #expect(!repo.hasTag("v1.2.3", in: repo.origin))
    }
}

@Suite("Build script", .serialized)
struct BuildScriptTests {
    /// A copy of the repo's build script and Info.plist in a temp folder, with
    /// fake `swift` and `codesign` on PATH: `swift build` only notes that it
    /// ran, and `--show-bin-path` points at two stand-in binaries. HOME is the
    /// temp folder too, so nothing reaches the real `~/Applications`.
    private struct Checkout {
        let root: TempDirectory
        var work: String { root.file("work") }
        var buildLog: String { root.file("swift-log") }

        init(buildInfo: String? = nil) throws {
            root = try TempDirectory()
            for script in ["build.sh", "build-info.sh"] {
                let text = try String(contentsOfFile: "\(repoRoot)/scripts/\(script)", encoding: .utf8)
                try root.write("work/scripts/\(script)", text, executable: true)
            }
            if let buildInfo { try root.write("work/scripts/build-info.sh", buildInfo, executable: true) }
            let plist = try String(contentsOfFile: "\(repoRoot)/Packaging/Info.plist", encoding: .utf8)
            try root.write("work/Packaging/Info.plist", plist)
            try root.write("products/UsageBar", "#!/bin/sh\n", executable: true)
            try root.write("products/usagebar-statusline", "#!/bin/sh\n", executable: true)
            try root.write("bin/swift", """
                #!/bin/sh
                case " $* " in
                  *" --show-bin-path "*) echo "\(root.file("products"))" ;;
                  *) echo "swift $*" >> "\(buildLog)" ;;
                esac
                """, executable: true)
            try root.write("bin/codesign", "#!/bin/sh\n", executable: true)
        }

        func build(app: String) -> CommandResult {
            shell("/bin/bash", ["scripts/build.sh"], in: work,
                  environment: ["PATH": root.file("bin") + ":/usr/bin:/bin", "HOME": root.path, "USAGEBAR_APP": app])
        }

        var built: Bool { FileManager.default.fileExists(atPath: buildLog) }
    }

    @Test("an absolute .app path is built, packaged and replaces the app there")
    func packages() throws {
        let checkout = try Checkout()
        defer { checkout.root.remove() }
        let app = checkout.root.file("Apps/UsageBar.app")
        try checkout.root.write("Apps/UsageBar.app/Contents/Info.plist", "<plist/>")
        try checkout.root.write("Apps/UsageBar.app/Contents/old", "previous build")
        let result = checkout.build(app: app)
        #expect(result.status == 0, "\(result.output)")
        #expect(FileManager.default.isExecutableFile(atPath: app + "/Contents/MacOS/UsageBar"))
        #expect(FileManager.default.isExecutableFile(atPath: app + "/Contents/Helpers/usagebar-statusline"))
        #expect(!FileManager.default.fileExists(atPath: app + "/Contents/old"))
    }

    @Test("USAGEBAR_APP that isn't an absolute path to a .app is refused before building, deleting nothing",
          arguments: ["Apps", "Apps/", "UsageBar.app", "./UsageBar.app", "Apps/UsageBar", "Apps/.app", "Apps/../Apps", "Apps/UsageBar.app/", "notes.app", "Docs.app"])
    func refusesInstallPath(name: String) throws {
        let checkout = try Checkout()
        defer { checkout.root.remove() }
        // Something to lose at each path the value could name.
        try checkout.root.write("Apps/keep", "an unrelated file")
        try checkout.root.write("Apps/UsageBar", "an unrelated file")
        try checkout.root.write("work/UsageBar.app/keep", "an unrelated file")
        try checkout.root.write("notes.app", "a file, not an app")
        try checkout.root.write("Docs.app/keep", "a folder, not an app")
        let app = name.hasPrefix(".") || name == "UsageBar.app" ? name : checkout.root.file(name) + (name.hasSuffix("/") ? "/" : "")
        let result = checkout.build(app: app)
        #expect(result.status != 0)
        #expect(result.output.contains("USAGEBAR_APP"), "\(result.output)")
        #expect(!checkout.built)
        for kept in ["Apps/keep", "Apps/UsageBar", "work/UsageBar.app/keep", "notes.app", "Docs.app/keep"] {
            #expect(FileManager.default.fileExists(atPath: checkout.root.file(kept)), "\(kept) was deleted")
        }
    }

    @Test("a failing build-info.sh stops the build before the app is replaced")
    func buildInfoFails() throws {
        let checkout = try Checkout(buildInfo: "#!/bin/bash\necho 'build-info: broken' >&2\nexit 3\n")
        defer { checkout.root.remove() }
        let app = checkout.root.file("Apps/UsageBar.app")
        try checkout.root.write("Apps/UsageBar.app/Contents/Info.plist", "<plist/>")
        try checkout.root.write("Apps/UsageBar.app/Contents/old", "previous build")
        let result = checkout.build(app: app)
        #expect(result.status != 0)
        #expect(result.output.contains("build-info: broken"))
        #expect(!result.output.contains("Built "))
        #expect(!checkout.built, "build-info.sh runs before the slow build")
        #expect(FileManager.default.fileExists(atPath: app + "/Contents/old"))
        #expect(!FileManager.default.fileExists(atPath: app + "/Contents/MacOS/UsageBar"))
    }
}
