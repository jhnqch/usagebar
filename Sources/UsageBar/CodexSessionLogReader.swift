import Foundation
import UsageCore

/// Finds the latest Codex rate-limit record in the session logs under
/// `~/.codex/sessions` (or `$CODEX_HOME/sessions`). Reads only `.jsonl`
/// session files, never Codex's login.
actor CodexSessionLogReader {
    static let defaultDirectory: URL = {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        return home.appending(path: "sessions")
    }()

    /// How much of the end of each file to read: the last record is near it.
    private static let tailBytes = 4 * 1024 * 1024
    /// How many of the most recently changed files to look at, at most.
    private static let maxFiles = 10

    private let directory: URL
    /// Each file's latest reading, keyed by path, valid while its size and
    /// modification time are unchanged.
    private var cache: [String: (stamp: Stamp, limits: CodexLimits?)] = [:]

    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    init(directory: URL = defaultDirectory) {
        self.directory = directory
    }

    func latest() -> CodexLimits? {
        let files = recentFiles()
        let paths = Set(files.map(\.0.path))
        cache = cache.filter { paths.contains($0.key) }
        var best: CodexLimits?
        for (url, stamp) in files {
            // A file can't hold a record newer than its last change.
            if let found = best?.capturedAt, stamp.modified < found { break }
            let limits = limits(in: url, stamp: stamp)
            if let limits, (limits.capturedAt ?? .distantPast) >= (best?.capturedAt ?? .distantPast) {
                best = limits
            }
        }
        return best
    }

    /// The most recently changed session files, newest first.
    private func recentFiles() -> [(URL, Stamp)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var found: [(URL, Stamp)] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let modified = values.contentModificationDate
            else { continue }
            found.append((url, Stamp(modified: modified, size: values.fileSize ?? 0)))
        }
        return Array(found.sorted { $0.1.modified > $1.1.modified }.prefix(Self.maxFiles))
    }

    private func limits(in url: URL, stamp: Stamp) -> CodexLimits? {
        if let cached = cache[url.path], cached.stamp == stamp { return cached.limits }
        let limits = tail(of: url, size: stamp.size).flatMap(CodexSessionLog.latestLimits(in:))
        cache[url.path] = (stamp, limits)
        return limits
    }

    private func tail(of url: URL, size: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(max(0, size - Self.tailBytes)))
        return try? handle.readToEnd()
    }
}
