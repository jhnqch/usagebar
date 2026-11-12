import Foundation

/// Ends a long-running child process such as `codex app-server`.
public enum ChildProcess {
    /// Sends SIGTERM, waits up to `grace` seconds for the child to exit, then
    /// sends SIGKILL to one that ignored it. Blocks for up to `grace`, so
    /// call it off the main actor unless the wait is the point (quitting).
    /// A child that already exited is left alone.
    public static func end(_ process: Process, grace: TimeInterval = 1) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
