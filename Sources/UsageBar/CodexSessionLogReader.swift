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
    /// Each file's last record, keyed by path, valid while its size and
    /// modification time are unchanged.
    private var cache: [String: (stamp: Stamp, record: CodexSessionLog.Record?)] = [:]

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
        // The newest record across files, by its timestamp or, when that
        // can't be read, by its file's last change.
        var best: (record: CodexSessionLog.Record, time: Date)?
        for (url, stamp) in files {
            // A file can't hold a record newer than its last change.
            if let best, stamp.modified < best.time { break }
            guard let record = record(in: url, stamp: stamp) else { continue }
            let time = record.capturedAt ?? stamp.modified
            if time >= best?.time ?? .distantPast {
                best = (record, time)
            }
        }
        // An unreadable newest record gives nil: an older reading is stale.
        return best?.record.limits
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

    private func record(in url: URL, stamp: Stamp) -> CodexSessionLog.Record? {
        if let cached = cache[url.path], cached.stamp == stamp { return cached.record }
        let record = tail(of: url, size: stamp.size).flatMap(CodexSessionLog.lastRecord(in:))
        cache[url.path] = (stamp, record)
        return record
    }

    private func tail(of url: URL, size: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(max(0, size - Self.tailBytes)))
        return try? handle.readToEnd()
    }
}
