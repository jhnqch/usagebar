import Foundation

/// A repository on github.com, `owner/name`.
public struct GitHubRepository: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var owner: String
    public var name: String

    /// Parses `owner/name`; nil unless both are made of GitHub's name
    /// characters (letters, digits, `-`, `_`, `.`), so either is safe in a
    /// URL path.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(Self.isName) else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }

    /// The repository a git remote URL points at, when it's on github.com:
    /// `https://github.com/o/n(.git)`, `git@github.com:o/n.git` or
    /// `ssh://git@github.com/o/n.git`. Nil for any other host, port or shape.
    public init?(remoteURL: String) {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: Substring
        if let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(), ["https", "ssh"].contains(scheme) {
            guard url.host?.lowercased() == "github.com", url.port == nil else { return nil }
            path = Substring(url.path)
            guard path.first == "/" else { return nil }
            path = path.dropFirst()
        } else if let colon = text.firstIndex(of: ":"), !text.contains("://") {
            // scp-like: [user@]github.com:owner/name.git
            let host = text[..<colon].split(separator: "@").last.map { $0.lowercased() }
            guard host == "github.com" else { return nil }
            path = text[text.index(after: colon)...]
        } else {
            return nil
        }
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        self.init(String(path))
    }

    public var description: String { "\(owner)/\(name)" }

    private static func isName(_ part: Substring) -> Bool {
        !part.isEmpty && part != "." && part != ".."
            && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
}

/// A published release newer builds can update to.
public struct Release: Equatable, Sendable {
    public var version: SemanticVersion
    /// The git tag, as GitHub names it: `v1.2.0`.
    public var tag: String
    /// The release's page on github.com; nil when missing or elsewhere.
    public var page: URL?

    public init(version: SemanticVersion, tag: String, page: URL? = nil) {
        self.version = version
        self.tag = tag
        self.page = page
    }
}

/// What one look at the latest release found.
public enum ReleaseCheck: Equatable, Sendable {
    /// The latest published, stable release.
    case release(Release)
    /// No release to offer: none published, a draft or prerelease, or an
    /// answer without a usable version tag.
    case noRelease
    /// GitHub answered with an error.
    case failed(String)
    /// No answer: offline or timed out. Doesn't count as a check.
    case unreachable
}

/// The update check: `GET https://api.github.com/repos/<owner>/<name>/releases/latest`
/// with no token, and how to read the answer.
public enum GitHubRelease {
    /// The request for `repository`'s latest release. No credentials or
    /// cookies; nothing is sent but the request itself.
    public static func request(for repository: GitHubRepository, userAgent: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository.owner)/\(repository.name)/releases/latest"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Reads the answer. Missing or extra fields are tolerated; only a
    /// stable `vX.Y.Z` (or `X.Y.Z`) tag that isn't a draft or prerelease
    /// makes a release.
    public static func check(_ outcome: PollOutcome) -> ReleaseCheck {
        switch outcome {
        case .networkError, .noCredentials, .blocked:
            return .unreachable
        case let .response(status, body, _):
            if status == 404 { return .noRelease }
            guard status == 200 else { return .failed("GitHub answered \(status)") }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let version = SemanticVersion(tag), !version.isPrerelease,
                  object["draft"] as? Bool != true, object["prerelease"] as? Bool != true
            else { return .noRelease }
            let page = (object["html_url"] as? String).flatMap(URL.init(string:))
                .filter { $0.scheme == "https" && $0.host?.lowercased() == "github.com" }
            return .release(Release(version: version, tag: tag, page: page))
        }
    }
}

private extension Optional {
    func filter(_ isIncluded: (Wrapped) -> Bool) -> Wrapped? {
        flatMap { isIncluded($0) ? $0 : nil }
    }
}

/// What `scripts/build.sh` recorded in the app's Info.plist: the version
/// (`git describe --tags`), the GitHub repo `origin` points at, and the
/// source checkout's path. Any of them may be missing, e.g. for a build
/// from a tarball.
public struct BuildInfo: Equatable, Sendable {
    public var version: BuildVersion?
    public var repository: GitHubRepository?
    /// An absolute path.
    public var sourcePath: String?

    public static let versionKey = "UsageBarVersion"
    public static let repositoryKey = "UsageBarRepository"
    public static let sourcePathKey = "UsageBarSourcePath"

    public init(version: BuildVersion? = nil, repository: GitHubRepository? = nil, sourcePath: String? = nil) {
        self.version = version
        self.repository = repository
        self.sourcePath = sourcePath
    }

    /// Reads the keys; a missing, empty, mistyped or malformed one is nil.
    public init(infoDictionary: [String: Any]) {
        version = (infoDictionary[Self.versionKey] as? String).flatMap { BuildVersion(describe: $0) }
        repository = (infoDictionary[Self.repositoryKey] as? String).flatMap { GitHubRepository($0) }
        sourcePath = (infoDictionary[Self.sourcePathKey] as? String).filter { $0.hasPrefix("/") }
    }
}
