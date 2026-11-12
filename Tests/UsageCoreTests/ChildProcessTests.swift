import Foundation
import Testing
import ProcessRunner

/// Ending a child process UsageBar runs (app-server): SIGTERM first, then
/// SIGKILL after a grace period for one that ignores it.
@Suite("Ending a child process", .serialized)
struct ChildProcessTests {
    /// Starts `script` under `/bin/sh` and waits for it to print a line.
    func started(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        _ = output.fileHandleForReading.availableData
        return process
    }

    @Test("a child that ignores SIGTERM is killed after the grace period")
    func ignoresTerm() throws {
        let process = try started(#"trap "" TERM; echo ready; exec /bin/sleep 30"#)
        let began = Date()
        ChildProcess.end(process, grace: 0.3)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(Date().timeIntervalSince(began) < 5)
    }

    @Test("a child that exits on SIGTERM isn't killed")
    func exitsOnTerm() throws {
        let process = try started("echo ready; exec /bin/sleep 30")
        ChildProcess.end(process, grace: 5)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    @Test("a child that already exited is left alone")
    func alreadyExited() throws {
        let process = try started("echo ready")
        process.waitUntilExit()
        ChildProcess.end(process, grace: 0.1)
        #expect(process.terminationStatus == 0)
    }
}
