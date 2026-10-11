import Foundation
import UsageCore

/// Reads Claude Code's transcripts under `~/.claude/projects` (or
/// `$CLAUDE_CONFIG_DIR/projects`): every `.jsonl` at any depth, so session
/// files and their subagents' files alike. Runs off the main thread as an
/// actor; `TranscriptScan` decides what to read, so a rescan reads only the
/// bytes appended since the last one. Reads transcripts only, never Claude
/// Code's login.
actor ClaudeTranscriptReader {
    static let defaultDirectory: URL = {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        return config.appending(path: "projects")
    }()

    private let directory: URL
    private var transcripts = TranscriptScan()

    init(directory: URL = defaultDirectory) {
        self.directory = directory
    }

    /// Every reply logged since `since`, de-duplicated, after reading what's
    /// new in the transcripts.
    func scan(since: Date) -> [UsageEntry] {
        for read in transcripts.reads(for: files(), since: since) {
            if let bytes = bytes(read) {
                transcripts.receive(bytes, for: read)
            }
        }
        return transcripts.entries
    }

    private func files() -> [TranscriptScan.File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [TranscriptScan.File] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let modified = values.contentModificationDate
            else { continue }
            files.append(TranscriptScan.File(
                path: url.path,
                size: values.fileSize ?? 0,
                modified: modified,
                identity: values.fileIdentifier ?? 0
            ))
        }
        return files
    }

    private func bytes(_ read: TranscriptScan.Read) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: read.path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(read.offset))
            return try handle.read(upToCount: read.length)
        } catch {
            return nil
        }
    }
}
