import Foundation
import OSLog
import UsageCore

/// Keeps the model's status line reading current. The status line command
/// replaces its file by renaming a new one over it, so this watches the
/// support directory (whose entries change on every save) rather than the
/// file, and rereads the file at launch, on every change and on refresh.
@MainActor
final class ClaudeStatusLineMonitor {
    private let model: AppModel
    private let file: URL
    private var source: DispatchSourceFileSystemObject?
    private var lastLimits: ClaudeLimits?
    private let log = Logger(subsystem: "io.github.jhnqch.usagebar", category: "claude-status-line")

    static let defaultFile = ClaudeStatusLine
        .supportDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
        .appending(path: ClaudeStatusLine.fileName)

    init(model: AppModel, file: URL = defaultFile) {
        self.model = model
        self.file = file
    }

    func start() {
        watch()
        read()
    }

    func refresh() {
        // The directory may have been created or replaced since the last watch.
        if source == nil { watch() }
        read()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func watch() {
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("can't create \(directory.path, privacy: .public): \(error, privacy: .public)")
        }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("can't watch \(directory.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let directoryGone = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                if directoryGone {
                    // Watch the new directory instead of the old one.
                    self.stop()
                    self.watch()
                }
                self.read()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func read() {
        let limits = (try? Data(contentsOf: file)).flatMap(ClaudeStatusLine.limits(fromSaved:))
        if limits != lastLimits {
            lastLimits = limits
            let windows = [limits?.fiveHour.map { "5h \(Int($0.usedPercent))%" }, limits?.sevenDay.map { "wk \(Int($0.usedPercent))%" }]
            log.info("Claude limits from the status line: \(windows.compactMap(\.self), privacy: .public)")
        }
        model.update { $0.claudeStatusLine = limits }
    }
}
