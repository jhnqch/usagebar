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
            try root.write("bin/gh", "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/../gh-args\"\n", executable: true)
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

    @Test("a tag that already exists, here or on origin, is refused")
    func exists() throws {
        let repo = try Repo()
        defer { repo.root.remove() }
        git("tag", "v1.0.0", in: repo.work)
        #expect(repo.release("v1.0.0").output.contains("v1.0.0 already exists"))
        git("tag", "v1.1.0", "main", in: repo.origin)
        let result = repo.release("v1.1.0")
        #expect(result.status != 0)
        #expect(result.output.contains("v1.1.0 already exists"))
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
