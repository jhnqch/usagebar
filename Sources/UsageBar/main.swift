import AppKit
import UsageCore

let arguments = CommandLine.arguments

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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(model: AppModel(readings: SampleReadings.load()))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
