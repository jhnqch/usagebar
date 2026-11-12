import Foundation

/// Runs a command as a child process with the app's environment plus the
/// command's, and the system's tool directories on PATH (an app launched
/// from Finder gets a bare one). Waits on a dispatch thread, not the
/// concurrency pool, since a build takes minutes.
///
/// The child leads a process group of its own, so at its deadline the whole
/// group is stopped: `git fetch`'s transport helper and the compilers a build
/// starts as well as the command itself. First SIGTERM, then SIGKILL for
/// whatever is left after a grace period. A process the command left behind
/// that still holds its output open counts as the command still running.
public struct ProcessCommandRunner: CommandRunner {
    /// Between the polite stop and the forced one.
    static let grace: TimeInterval = 2

    public init() {}

    public func run(_ command: Command) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runToEnd(command))
            }
        }
    }

    private static func runToEnd(_ command: Command) -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"].map { $0 + ":" } ?? ""
        environment["PATH"] = path + "/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(command.environment) { $1 }

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return CommandResult(status: -1, output: String(cString: strerror(errno))) }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }

        guard let pid = spawn(command, environment: environment, output: writeEnd) else {
            let message = String(cString: strerror(errno))
            close(writeEnd)
            return CommandResult(status: -1, output: message)
        }
        close(writeEnd)
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        let deadline = command.timeout.map { Date().addingTimeInterval($0) }
        var output = Data()
        var exitStatus: Int32?
        var atEnd = false
        var termSent: Date?
        var killSent: Date?
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while exitStatus == nil || !atEnd {
            if !atEnd {
                var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                if poll(&poller, 1, 100) > 0 {
                    let count = read(readEnd, &buffer, buffer.count)
                    if count > 0 {
                        output.append(buffer, count: count)
                    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        atEnd = true
                    }
                }
            } else {
                usleep(50_000)
            }
            if exitStatus == nil {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid { exitStatus = status }
            }
            let now = Date()
            if termSent == nil, let deadline, now >= deadline {
                killpg(pid, SIGTERM)
                termSent = now
            } else if let sent = termSent, killSent == nil, now.timeIntervalSince(sent) >= grace {
                killpg(pid, SIGKILL)
                killSent = now
            } else if let sent = killSent, now.timeIntervalSince(sent) >= grace {
                // Something outside the group holds the output open: stop
                // listening. The child itself can't outlive SIGKILL.
                if exitStatus == nil {
                    var status: Int32 = 0
                    if waitpid(pid, &status, 0) == pid { exitStatus = status }
                }
                break
            }
        }
        if termSent != nil {
            // The group may outlive its leader; nothing of it is left behind.
            killpg(pid, SIGKILL)
        }

        return CommandResult(status: exitStatus.map(shellStatus) ?? -1, output: String(decoding: output, as: UTF8.self),
                             timedOut: termSent != nil)
    }

    /// Starts the command in its own process group, stdin from /dev/null and
    /// stdout and stderr into `output`, no other descriptors inherited. Nil,
    /// with `errno` set, when it can't start.
    private static func spawn(_ command: Command, environment: [String: String], output: Int32) -> pid_t? {
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        posix_spawn_file_actions_addchdir(&actions, command.directory)

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, command.executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            errno = result
            return nil
        }
        return pid
    }

    /// A wait status as a shell reports it: the exit code, or 128 plus the
    /// signal that ended the process.
    private static func shellStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
