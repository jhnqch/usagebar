import Foundation
import UsageCore

/// The status line itself: stdin in, saved file and one line out. Thin: the
/// decisions are in `ClaudeStatusLine.run`.
enum StatusLineCommand {
    static func run() {
        // Run by hand in a terminal, there's no JSON coming.
        guard isatty(STDIN_FILENO) == 0 else {
            FileHandle.standardError.write(Data(Usage.text.utf8))
            return
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let directory = ClaudeStatusLine.supportDirectory(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        let file = directory.appending(path: ClaudeStatusLine.fileName)

        var result = ClaudeStatusLine.run(input: input, saved: nil, now: Date())
        if result.save != nil {
            // Sessions run this concurrently; read, merge and write under a lock.
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try withLock(in: directory) {
                    result = ClaudeStatusLine.run(input: input, saved: try? Data(contentsOf: file), now: Date())
                    if let save = result.save {
                        try writeAtomically(save, to: file)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("usagebar-statusline: couldn't save rate limits: \(error)\n".utf8))
            }
        }
        print(result.line)
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Writes to a temp file beside `file`, then renames it over `file`, so
    /// the app never reads half a file.
    private static func writeAtomically(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).\(getpid()).tmp")
        try data.write(to: temp)
        guard rename(temp.path, file.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temp.path)
            throw Failure(description: "rename failed: \(reason)")
        }
    }

    /// Runs `body` holding an exclusive lock on a lock file in `directory`.
    /// Waits up to half a second, then gives up: Claude Code cancels a slow
    /// status line anyway, and the next run saves.
    private static func withLock(in directory: URL, _ body: () throws -> Void) throws {
        let path = directory.appending(path: ".\(ClaudeStatusLine.fileName).lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure(description: "can't open \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(0.5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw Failure(description: "another status line held the lock") }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        try body()
    }
}
