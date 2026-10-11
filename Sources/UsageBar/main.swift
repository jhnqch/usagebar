import AppKit
import UsageCore

let arguments = CommandLine.arguments

// Writing to an app-server that just exited must fail, not kill the app.
signal(SIGPIPE, SIG_IGN)

if let flag = arguments.firstIndex(of: "--snapshot") {
    guard arguments.count > flag + 2 else {
        FileHandle.standardError.write(Data("usage: UsageBar --snapshot <fixture.json> <out.png>\n".utf8))
        exit(64)
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    do {
        try MainActor.assumeIsolated {
            try SnapshotMode.render(fixturePath: arguments[flag + 1], outputPath: arguments[flag + 2])
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}

// `UsageBar --claude-usage [days]`: scans Claude Code's transcripts as the
// app does and prints each model's tokens and dollars for the last `days`
// days (default 7), for checking the scanner against the logs.
if let flag = arguments.firstIndex(of: "--claude-usage") {
    let days = arguments.count > flag + 1 ? Double(arguments[flag + 1]) ?? 7 : 7
    let since = Date() - days * 24 * 60 * 60
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let reader = ClaudeTranscriptReader()
        let started = ContinuousClock.now
        let entries = await reader.scan(since: since)
        let scanned = ContinuousClock.now
        // A rescan reads only what was appended since.
        _ = await reader.scan(since: since)
        print(ClaudeUsageReport.text(entries, since: since, prices: .claude))
        print("scanned in \(scanned - started), rescanned in \(ContinuousClock.now - scanned)")
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(model: AppModel(readings: SampleReadings.load()))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
