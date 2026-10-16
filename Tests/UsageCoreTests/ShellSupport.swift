import Foundation
import UsageCore

/// Runs real commands for the tests that drive git and the scripts in temp
/// directories. Git sees no global or system config, so the user's own
/// settings (signing, hooks, aliases) can't change the outcome.
struct TestCommandRunner: CommandRunner {
    static let isolatedEnvironment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ]

    func run(_ command: Command) async -> CommandResult {
        shell(command.executable, command.arguments, in: command.directory, environment: command.environment)
    }
}

/// Runs a command to the end and returns its status and combined output.
@discardableResult
func shell(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String] = [:]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.environment = ProcessInfo.processInfo.environment
        .merging(TestCommandRunner.isolatedEnvironment) { $1 }
        .merging(environment) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return CommandResult(status: -1, output: "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

/// git in `directory`; fails the caller's expectations through its status.
@discardableResult
func git(_ arguments: String..., in directory: String) -> CommandResult {
    shell("/usr/bin/git", arguments, in: directory)
}

/// A fresh temp directory, resolved past `/tmp`'s symlink as `pwd -P` and
/// git report it. Removed when the test's `defer` calls `remove()`.
struct TempDirectory {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "usagebar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Not `resolvingSymlinksInPath()`, which puts `/var` back for `/private/var`.
        guard let real = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        path = String(cString: real)
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    func write(_ name: String, _ text: String, executable: Bool = false) throws {
        let target = file(name)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: target, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The repo's root, for its scripts.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // UsageCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .path
