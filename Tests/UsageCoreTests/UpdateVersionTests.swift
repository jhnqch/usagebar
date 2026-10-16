import Foundation
import Testing
import UsageCore

@Suite("Update versions")
struct UpdateVersionTests {
    @Test("release tags parse with or without the v", arguments: [
        ("v1.2.3", "1.2.3"), ("1.2.3", "1.2.3"), ("v10.0.12", "10.0.12"), ("v1.0.0-rc.1", "1.0.0-rc.1"),
    ])
    func parses(tag: String, text: String) throws {
        #expect(try #require(SemanticVersion(tag)).description == text)
    }

    @Test("malformed tags don't parse", arguments: [
        "", "v", "1.2", "v1.2.3.4", "release-5", "v01.2.3", "v1.02.3", "vv1.2.3", "v1.2.3-", "v1.2.3-rc..1", "V1.2.3x", " v1.2.3", "v-1.2.3",
    ])
    func malformed(tag: String) {
        #expect(SemanticVersion(tag) == nil)
    }

    @Test("versions order as semver: numbers numerically, a prerelease before its release")
    func ordering() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                       "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0"]
        let versions = try ordered.map { try #require(SemanticVersion($0)) }
        #expect(versions.sorted() == versions)
        #expect(versions.shuffled().sorted() == versions)
        #expect(SemanticVersion("v1.2.3") == SemanticVersion("1.2.3"))
        #expect(SemanticVersion("1.2.3+build.5") == SemanticVersion("1.2.3"))
    }

    @Test("a build at a tag is older only than a later release")
    func buildAtTag() throws {
        let build = try #require(BuildVersion(describe: "v1.1.0"))
        #expect(build.text == "v1.1.0")
        #expect(build.isOlder(than: try #require(SemanticVersion("1.2.0"))))
        #expect(build.isOlder(than: try #require(SemanticVersion("1.1.1"))))
        #expect(!build.isOlder(than: try #require(SemanticVersion("1.1.0"))))
        #expect(!build.isOlder(than: try #require(SemanticVersion("1.0.9"))))
    }

    @Test("a build commits past a tag is newer than that tag but older than the next")
    func buildPastTag() throws {
        let build = try #require(BuildVersion(describe: "v1.1.0-3-gabc1234"))
        #expect(build.text == "v1.1.0 + 3 commits")
        #expect(!build.isOlder(than: try #require(SemanticVersion("1.1.0"))))
        #expect(build.isOlder(than: try #require(SemanticVersion("1.1.1"))))

        let prerelease = try #require(BuildVersion(describe: "v2.0.0-rc.1-12-g0123abcd"))
        #expect(prerelease.isOlder(than: try #require(SemanticVersion("2.0.0"))))
    }

    @Test("describe output that isn't a version tag doesn't parse", arguments: ["abc1234", "", "nightly-3-gabc", "v1.2-3-gabc"])
    func notADescribe(text: String) {
        #expect(BuildVersion(describe: text) == nil)
    }
}
