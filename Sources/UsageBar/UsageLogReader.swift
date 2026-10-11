import Foundation
import UsageCore

/// Reads usage logs: every `.jsonl` at any depth under its directories.
/// Runs off the main thread as an actor; `UsageLogScan` decides what to
/// read, so a rescan reads only the bytes appended since the last one.
/// Reads the logs only, never Claude Code's or Codex's login.
actor UsageLogReader<Parser: UsageLogParser> {
    private let directories: [URL]
    private var scan = UsageLogScan<Parser>()

    init(directories: [URL]) {
        self.directories = directories
    }

    /// Every usage entry logged since `since`, after reading what's new.
    func scan(since: Date) -> [UsageEntry] {
        for read in scan.reads(for: files(), since: since) {
            if let bytes = bytes(read) {
                scan.receive(bytes, for: read)
            }
        }
        return scan.entries
    }

    private func files() -> [UsageLogScan<Parser>.File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileIdentifierKey]
        var files: [UsageLogScan<Parser>.File] = []
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard
                    let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true,
                    let modified = values.contentModificationDate
                else { continue }
                files.append(UsageLogScan<Parser>.File(
                    path: url.path,
                    size: values.fileSize ?? 0,
                    modified: modified,
                    identity: values.fileIdentifier ?? 0
                ))
            }
        }
        return files
    }

    private func bytes(_ read: UsageLogScan<Parser>.Read) -> Data? {
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

/// Where each tool keeps its usage logs.
enum UsageLogs {
    /// Claude Code's transcripts: `~/.claude/projects` (or
    /// `$CLAUDE_CONFIG_DIR/projects`), session files and their subagents'.
    static let claudeProjects: [URL] = {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        return [config.appending(path: "projects")]
    }()

    /// Codex's rollout files: `~/.codex/sessions` (or `$CODEX_HOME/sessions`),
    /// and `archived_sessions`, where archiving moves a session's file.
    static let codexSessions: [URL] = [
        codexHome.appending(path: "sessions"),
        codexHome.appending(path: "archived_sessions"),
    ]

    /// `~/.codex`, or `$CODEX_HOME`.
    static let codexHome: URL = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
}
