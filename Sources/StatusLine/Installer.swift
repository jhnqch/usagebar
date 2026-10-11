import Foundation
import UsageCore

/// `usagebar-statusline install <settings.json> [--replace]`: points Claude
/// Code's `statusLine` at this executable. Backs the file up before changing
/// it, keeps every other setting, and refuses to replace a different status
/// line unless asked to.
enum Installer {
    static func run(_ arguments: [String]) -> Int32 {
        let replacing = arguments.contains("--replace")
        let paths = arguments.filter { $0 != "--replace" }
        guard paths.count == 1, !paths[0].hasPrefix("-") else {
            fail(Usage.text)
            return 64
        }
        // Write through a symlink (a dotfiles repo, say) rather than over it.
        let settings = URL(fileURLWithPath: paths[0]).standardizedFileURL.resolvingSymlinksInPath()
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            fail("can't find this executable's path")
            return 1
        }
        if !executable.contains(".app/Contents/") {
            fail("warning: \(executable) isn't inside UsageBar.app, so the status line breaks if it moves")
        }
        let command = ClaudeSettings.shellCommand(forExecutable: executable)

        var isDirectory: ObjCBool = false
        let folder = settings.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("\(folder) doesn't exist")
            return 1
        }
        let existing: String?
        if FileManager.default.fileExists(atPath: settings.path) {
            guard let data = FileManager.default.contents(atPath: settings.path) else {
                fail("can't read \(settings.path)")
                return 1
            }
            existing = String(decoding: data, as: UTF8.self)
        } else {
            existing = nil
        }

        do {
            switch try ClaudeSettings.installingStatusLine(command: command, into: existing, replacing: replacing) {
            case .alreadyInstalled:
                print("\(settings.path): statusLine already runs \(command)")
                return 0
            case let .conflict(other):
                fail("""
                    \(settings.path) already has a different statusLine: \(other)
                    Nothing changed. Run again with --replace to replace it (the file is backed up first).
                    """)
                return 1
            case let .updated(text):
                if existing != nil {
                    let backup = try backUp(settings)
                    print("Backed up \(settings.path) to \(backup.path)")
                }
                try write(text, to: settings)
                print("Set statusLine in \(settings.path) to \(command)")
                return 0
            }
        } catch {
            fail("\(settings.path): \(error)")
            return 1
        }
    }

    /// Copies the settings file to `<name>.usagebar-backup-<yyyyMMdd-HHmmss>`.
    private static func backUp(_ settings: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(settings.lastPathComponent).usagebar-backup-\(formatter.string(from: Date()))"
        var backup = settings.deletingLastPathComponent().appending(path: stem)
        var attempt = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            attempt += 1
            backup = settings.deletingLastPathComponent().appending(path: "\(stem)-\(attempt)")
        }
        try FileManager.default.copyItem(at: settings, to: backup)
        return backup
    }

    /// Writes beside the file and renames over it, keeping its permissions.
    private static func write(_ text: String, to settings: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: settings.path))?[.posixPermissions]
        let temp = settings.deletingLastPathComponent().appending(path: ".\(settings.lastPathComponent).usagebar.tmp")
        try Data(text.utf8).write(to: temp)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        guard rename(temp.path, settings.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temp.path)
            throw StatusLineCommand.Failure(description: "couldn't replace the file: \(reason)")
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
    }
}
