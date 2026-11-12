import Foundation
import Testing
import UsageCore

/// Whether a process is still running (a zombie waiting to be reaped counts
/// as gone: `ps` reports it as `Z`).
private func isRunning(_ pid: Int32) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    let state = shell("/bin/ps", ["-o", "stat=", "-p", String(pid)], in: "/").output
    return !state.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
}

/// Waits up to two seconds for `pid` to be gone.
private func isGone(_ pid: Int32) async -> Bool {
    for _ in 0..<40 {
        if !isRunning(pid) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

@Suite("Process command runner", .serialized)
struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner()

    @Test("runs in the command's directory with its environment, output and errors together")
    func runs() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let result = await runner.run(Command("/bin/sh", ["-c", "pwd -P; echo \"$GREETING\"; echo oops >&2; exit 3"], in: dir.path,
                                              environment: ["GREETING": "hello"]))
        #expect(result.status == 3)
        #expect(!result.timedOut)
        #expect(result.output == "\(dir.path)\nhello\noops\n")
    }

    @Test("a command that can't start, e.g. in a missing directory, reports -1")
    func cantStart() async throws {
        let result = await runner.run(Command("/bin/echo", ["hi"], in: "/nonexistent-usagebar-test-dir"))
        #expect(result.status == -1)
        #expect(!result.timedOut)
    }

    @Test("a command within its deadline runs to the end")
    func withinDeadline() async {
        let result = await runner.run(Command("/bin/sh", ["-c", "sleep 0.2; echo done"], in: "/", timeout: 10))
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.output == "done\n")
    }

    @Test("a command that outlives its deadline is stopped, with the processes it started")
    func stopsAtDeadline() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let pidFile = dir.file("child.pid")
        let started = Date()
        let result = await runner.run(Command("/bin/bash", ["-c", "echo started; sleep 30 & echo $! > \"$1\"; wait", "x", pidFile],
                                              in: dir.path, timeout: 0.5))
        #expect(result.timedOut)
        #expect(result.status != 0)
        #expect(result.output.hasPrefix("started\n"))
        #expect(Date().timeIntervalSince(started) < 10)
        let child = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await isGone(child))
    }

    @Test("a process the command started in a process group of its own, as SwiftPM starts compilers, is stopped too")
    func otherGroup() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let pidFile = dir.file("child.pid")
        // Job control puts each background job in a group of its own; a second level stands in for swift-build's compiler.
        let script = "set -m; bash -c 'sleep 30 & echo $! > \"$1\"; wait' x \"$1\" & wait"
        let result = await runner.run(Command("/bin/bash", ["-c", script, "x", pidFile], in: dir.path, timeout: 0.5))
        #expect(result.timedOut)
        let child = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(getpgid(child) != getpgid(getpid()))
        #expect(await isGone(child))
    }

    @Test("a process in a group of its own whose parent has already exited is stopped too")
    func orphanInOtherGroup() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let pidFile = dir.file("child.pid")
        let result = await runner.run(Command("/bin/bash", ["-c", "set -m; sleep 30 & echo $! > \"$1\"; exit 0", "x", pidFile],
                                              in: dir.path, timeout: 0.5))
        #expect(result.timedOut)
        let child = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await isGone(child))
    }

    @Test("a command that ignores the polite stop is killed")
    func ignoresTerm() async {
        let started = Date()
        let result = await runner.run(Command("/bin/bash", ["-c", "trap '' TERM; while true; do sleep 0.1; done"], in: "/", timeout: 0.3))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("a background process holding the output open can't outlast the deadline")
    func lingeringChild() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let pidFile = dir.file("child.pid")
        let started = Date()
        let result = await runner.run(Command("/bin/bash", ["-c", "sleep 30 & echo $! > \"$1\"; exit 0", "x", pidFile], in: dir.path, timeout: 0.5))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
        let child = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await isGone(child))
    }
}
