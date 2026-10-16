import Foundation

/// A semver version, `MAJOR.MINOR.PATCH` with optional prerelease
/// identifiers (`1.0.0-rc.1`). Build metadata (`+…`) is accepted and
/// ignored. Release tags are `vX.Y.Z`; the `v` is optional here.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Empty for a release.
    public var prerelease: [String]

    /// Parses `v1.2.3`, `1.2.3`, `1.2.3-rc.1` or `1.2.3+meta`; nil for
    /// anything else, including leading zeros and empty identifiers.
    public init?(_ text: String) {
        var rest = Substring(text)
        if rest.first == "v" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") {
            let meta = rest[rest.index(after: plus)...]
            guard Self.validIdentifiers(meta, numericLeadingZeros: true) else { return nil }
            rest = rest[..<plus]
        }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let pre = rest[rest.index(after: dash)...]
            guard Self.validIdentifiers(pre, numericLeadingZeros: false) else { return nil }
            prerelease = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap(Self.number)
        guard numbers.count == 3 else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        self.prerelease = prerelease
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// `1.2.3` or `1.2.3-rc.1`.
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// `v1.2.3`.
    public var tag: String { "v\(description)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch), right = (rhs.major, rhs.minor, rhs.patch)
        if left != right { return left < right }
        // A prerelease comes before its release.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true  // numeric identifiers sort first
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// A non-negative decimal without leading zeros.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit), text == "0" || text.first != "0", text.count < 10 else { return nil }
        return Int(text)
    }

    private static func validIdentifiers(_ text: Substring, numericLeadingZeros: Bool) -> Bool {
        let identifiers = text.split(separator: ".", omittingEmptySubsequences: false)
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }) else { return false }
            if !numericLeadingZeros, identifier.allSatisfy(\.isASCIIDigit), identifier.count > 1, identifier.first == "0" { return false }
            return true
        }
    }
}

/// The version a build was made from: `git describe --tags` at build time,
/// either a tag (`v1.1.0`) or commits past one (`v1.1.0-3-gabc1234`).
public struct BuildVersion: Equatable, Sendable {
    /// The tag the build is at or past.
    public var base: SemanticVersion
    /// Commits past `base`; 0 at the tag.
    public var commitsAhead: Int

    public init(base: SemanticVersion, commitsAhead: Int = 0) {
        self.base = base
        self.commitsAhead = commitsAhead
    }

    /// Parses `git describe --tags` output; nil when it isn't a version tag.
    public init?(describe text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `<tag>-<n>-g<hash>` first: a prerelease tag has dashes of its own.
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        if pieces.count >= 3,
           let last = pieces.last, last.first == "g", last.count > 1, last.dropFirst().allSatisfy(\.isHexDigit),
           let count = Int(pieces[pieces.count - 2]), count > 0,
           let base = SemanticVersion(pieces.dropLast(2).joined(separator: "-")) {
            self.init(base: base, commitsAhead: count)
        } else if let base = SemanticVersion(text) {
            self.init(base: base)
        } else {
            return nil
        }
    }

    /// "v1.1.0", or "v1.1.0 + 3 commits".
    public var text: String {
        switch commitsAhead {
        case 0: base.tag
        case 1: "\(base.tag) + 1 commit"
        default: "\(base.tag) + \(commitsAhead) commits"
        }
    }

    /// Whether `release` is newer than this build. A build past a tag
    /// already has that tag's changes.
    public func isOlder(than release: SemanticVersion) -> Bool {
        base < release
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
