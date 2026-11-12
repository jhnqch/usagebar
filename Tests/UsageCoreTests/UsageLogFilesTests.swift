import Foundation
import Testing
import UsageCore

/// Listing the usage logs to scan: every `.jsonl` at any depth under each
/// log folder.
@Suite("Usage log files")
struct UsageLogFilesTests {
    @Test("a log folder that is a symlink to a directory is listed through the link")
    func symlinkedRoot() throws {
        let root = try TempDirectory()
        defer { root.remove() }
        try root.write("real/project/session.jsonl", "{}\n")
        try root.write("real/project/notes.txt", "not a log\n")
        try FileManager.default.createSymbolicLink(atPath: root.file("projects"), withDestinationPath: root.file("real"))

        let files = TranscriptScan.files(under: [URL(fileURLWithPath: root.file("projects"))])
        #expect(files.map { ($0.path as NSString).lastPathComponent } == ["session.jsonl"])
        #expect(files.first?.size == 3)
    }

    @Test("a missing log folder lists nothing")
    func missingRoot() throws {
        let root = try TempDirectory()
        defer { root.remove() }
        #expect(TranscriptScan.files(under: [URL(fileURLWithPath: root.file("nope"))]).isEmpty)
    }
}
