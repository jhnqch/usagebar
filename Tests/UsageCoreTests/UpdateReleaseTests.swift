import Foundation
import Testing
import UsageCore

private func release(_ json: String, status: Int = 200) -> ReleaseCheck {
    GitHubRelease.check(.response(status: status, body: Data(json.utf8)))
}

@Suite("GitHub repository")
struct GitHubRepositoryTests {
    @Test("an origin on github.com names owner/name", arguments: [
        "https://github.com/acme/usagebar.git", "https://github.com/acme/usagebar", "https://github.com/acme/usagebar/",
        "git@github.com:acme/usagebar.git", "ssh://git@github.com/acme/usagebar.git", "https://GitHub.com/acme/usagebar.git",
        "https://someone@github.com/acme/usagebar.git",
    ])
    func github(url: String) throws {
        let repository = try #require(GitHubRepository(remoteURL: url))
        #expect(repository.description == "acme/usagebar")
    }

    @Test("an origin anywhere else isn't a GitHub repository", arguments: [
        "https://gitlab.com/acme/usagebar.git", "git@gitlab.com:acme/usagebar.git", "/Users/someone/usagebar.git",
        "file:///tmp/usagebar.git", "https://github.com.evil.example/acme/usagebar.git", "https://github.com/acme",
        "https://github.com/acme/usagebar/extra", "http://github.com/acme/usagebar.git", "https://github.com:8443/acme/usagebar.git", "",
    ])
    func notGitHub(url: String) {
        #expect(GitHubRepository(remoteURL: url) == nil)
    }

    @Test("owner/name only takes GitHub's characters", arguments: ["acme/usage bar", "acme/../x", "acme", "a/b/c", "/x", "acme/", "acme/usagebar?x=1"])
    func badNames(text: String) {
        #expect(GitHubRepository(text) == nil)
    }

    @Test("the check asks api.github.com for the latest release, with no credentials")
    func request() throws {
        let repository = try #require(GitHubRepository("acme/usage-bar.swift"))
        let request = GitHubRelease.request(for: repository, userAgent: "UsageBar/1.0.0")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/acme/usage-bar.swift/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UsageBar/1.0.0")
        #expect(request.httpShouldHandleCookies == false)
    }
}

@Suite("Latest release")
struct UpdateReleaseTests {
    @Test("a published release gives its version, tag and page")
    func published() {
        let check = release("""
        {"tag_name": "v1.2.0", "name": "UsageBar v1.2.0", "draft": false, "prerelease": false,
         "html_url": "https://github.com/acme/usagebar/releases/tag/v1.2.0", "assets": [], "extra": {"x": 1}}
        """)
        #expect(check == .release(Release(version: SemanticVersion("1.2.0")!, tag: "v1.2.0",
                                          page: URL(string: "https://github.com/acme/usagebar/releases/tag/v1.2.0"))))
    }

    @Test("missing draft, prerelease and page fields still read")
    func missingFields() {
        #expect(release(#"{"tag_name": "1.3.0"}"#) == .release(Release(version: SemanticVersion("1.3.0")!, tag: "1.3.0", page: nil)))
    }

    @Test("a page off github.com is dropped")
    func foreignPage() {
        let check = release(#"{"tag_name": "v1.2.0", "html_url": "https://evil.example/x"}"#)
        #expect(check == .release(Release(version: SemanticVersion("1.2.0")!, tag: "v1.2.0", page: nil)))
    }

    @Test("drafts and prereleases are ignored", arguments: [
        #"{"tag_name": "v1.2.0", "draft": true}"#,
        #"{"tag_name": "v1.2.0", "prerelease": true}"#,
        #"{"tag_name": "v1.2.0-rc.1", "prerelease": false}"#,
    ])
    func ignored(json: String) {
        #expect(release(json) == .noRelease)
    }

    @Test("a malformed tag or answer means no release", arguments: [
        #"{"tag_name": "latest"}"#, #"{"tag_name": "v1.2"}"#, #"{"tag_name": 12}"#, #"{"name": "v1.2.0"}"#, #"[]"#, "not json", "",
    ])
    func malformed(json: String) {
        #expect(release(json) == .noRelease)
    }

    @Test("a repo without releases has none")
    func notFound() {
        #expect(release(#"{"message": "Not Found"}"#, status: 404) == .noRelease)
    }

    @Test("an error answer fails the check; no answer at all is unreachable")
    func failures() {
        #expect(release(#"{"message": "API rate limit exceeded"}"#, status: 403) == .failed("GitHub answered 403"))
        #expect(release("", status: 500) == .failed("GitHub answered 500"))
        #expect(GitHubRelease.check(.networkError) == .unreachable)
    }
}

@Suite("Build info")
struct BuildInfoTests {
    @Test("build.sh's Info.plist keys give the version, repo and source")
    func full() throws {
        let info = BuildInfo(infoDictionary: [
            "UsageBarVersion": "v1.1.0-2-gabc1234", "UsageBarRepository": "acme/usagebar", "UsageBarSourcePath": "/src/usagebar",
        ])
        #expect(info.version == BuildVersion(describe: "v1.1.0-2-gabc1234"))
        #expect(info.repository == GitHubRepository("acme/usagebar"))
        #expect(info.sourcePath == "/src/usagebar")
    }

    @Test("missing, empty or mistyped keys read as unknown")
    func missing() {
        let info = BuildInfo(infoDictionary: ["UsageBarVersion": "", "UsageBarRepository": 3, "UsageBarSourcePath": "relative/path"])
        #expect(info.version == nil)
        #expect(info.repository == nil)
        #expect(info.sourcePath == nil)
        #expect(BuildInfo(infoDictionary: [:]) == BuildInfo())
    }
}
