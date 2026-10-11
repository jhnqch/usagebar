import Foundation

/// The status line installer's edit to Claude Code's settings file
/// (`settings.json`): point `statusLine` at UsageBar's command. Pure text in,
/// text out, so the edit changes only the `statusLine` setting and leaves
/// every other byte (order, spacing, other keys) as it was.
public enum ClaudeSettings {
    public enum Install: Equatable, Sendable {
        /// The new settings text.
        case updated(String)
        /// `statusLine` already runs this command; nothing to change.
        case alreadyInstalled
        /// Another status line is set. Nothing changed; `existing` is its command.
        case conflict(existing: String)
    }

    /// The settings file isn't a JSON object Claude Code could read, so
    /// it's left alone.
    public struct NotAnObject: Error, CustomStringConvertible {
        public var description: String { "the settings file isn't a valid JSON object" }
    }

    /// Sets `statusLine` to `{"type": "command", "command": command}` in
    /// `settings` (nil or blank when there's no settings file yet). An
    /// existing, different `statusLine` is a conflict unless `replacing`.
    public static func installingStatusLine(command: String, into settings: String?, replacing: Bool = false) throws -> Install {
        let bytes = Array((settings ?? "").utf8)
        guard !bytes.allSatisfy(Scanner.isWhitespace) else {
            return .updated("{\n" + member(command: command, indent: "  ") + "\n}\n")
        }
        var scanner = Scanner(bytes: bytes)
        // JSONSerialization lets some things through (a trailing comma, say)
        // that Claude Code wouldn't read; the scanner doesn't.
        guard
            let object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
            let layout = try? scanner.topLevelObject()
        else { throw NotAnObject() }

        if let existing = object["statusLine"] {
            let current = existing as? [String: Any]
            if current?["type"] as? String == "command", current?["command"] as? String == command {
                return .alreadyInstalled
            }
            // With duplicate keys, the last one is the one that counts.
            guard replacing, let old = layout.members.last(where: { $0.key == "statusLine" }) else {
                return .conflict(existing: current?["command"] as? String ?? describe(existing))
            }
            return .updated(splice(bytes, old.value, value(command: command, indent: layout.indent)))
        }
        guard let last = layout.members.last else {
            // An empty object: `{}`.
            return .updated(splice(bytes, layout.open + 1..<layout.close, "\n" + member(command: command, indent: "  ") + "\n"))
        }
        let addition = layout.indent.map { ",\n" + member(command: command, indent: $0) }
            ?? ", " + member(command: command, indent: nil)
        return .updated(splice(bytes, last.value.upperBound..<last.value.upperBound, addition))
    }

    /// The `statusLine` command that runs `path`. Claude Code runs the
    /// command in a shell, so a path with spaces or quotes is single-quoted.
    public static func shellCommand(forExecutable path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-+".unicodeScalars.contains($0) }
        return plain && path.unicodeScalars.allSatisfy(\.isASCII) ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `"statusLine": {...}` as a member indented by `indent`, or on one
    /// line when `indent` is nil.
    private static func member(command: String, indent: String?) -> String {
        (indent ?? "") + #""statusLine": "# + value(command: command, indent: indent)
    }

    /// The `statusLine` value: one field per line, nested one more `indent`
    /// deep, or on one line when `indent` is nil.
    private static func value(command: String, indent: String?) -> String {
        let fields = [#""type": "command""#, #""command": "# + jsonString(command)]
        guard let indent else { return "{ " + fields.joined(separator: ", ") + " }" }
        return "{\n" + fields.map { indent + indent + $0 }.joined(separator: ",\n") + "\n" + indent + "}"
    }

    private static func jsonString(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    private static func describe(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    private static func splice(_ bytes: [UInt8], _ range: Range<Int>, _ replacement: String) -> String {
        String(decoding: bytes[..<range.lowerBound] + Array(replacement.utf8) + bytes[range.upperBound...], as: UTF8.self)
    }
}

// MARK: - Finding the top-level members

extension ClaudeSettings {
    /// Where the top-level object's members sit in the file. Runs only on
    /// text JSONSerialization has already accepted as an object.
    struct Layout {
        struct Member {
            var key: String
            /// The value's bytes.
            var value: Range<Int>
        }

        var open: Int
        var close: Int
        var members: [Member]
        /// The first member's indent when members sit on their own lines
        /// (nil when the object is on one line).
        var indent: String?
    }

    struct Scanner {
        var bytes: [UInt8]
        var index = 0

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        struct Malformed: Error {}

        mutating func topLevelObject() throws -> Layout {
            skipWhitespace()
            let open = index
            try expect(UInt8(ascii: "{"))
            var members: [Layout.Member] = []
            var indent: String?
            skipWhitespace()
            if peek == UInt8(ascii: "}") {
                index += 1
                return Layout(open: open, close: index - 1, members: [], indent: nil)
            }
            while true {
                skipWhitespace()
                if members.isEmpty { indent = lineIndent(before: index) }
                let keyRange = try string()
                let key = (try? JSONSerialization.jsonObject(with: Data(bytes[keyRange]), options: .fragmentsAllowed)) as? String ?? ""
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                let start = index
                try value()
                members.append(Layout.Member(key: key, value: start..<index))
                skipWhitespace()
                if peek == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                let close = index
                try expect(UInt8(ascii: "}"))
                return Layout(open: open, close: close, members: members, indent: indent)
            }
        }

        private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        private mutating func skipWhitespace() {
            while let byte = peek, Self.isWhitespace(byte) { index += 1 }
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard peek == byte else { throw Malformed() }
            index += 1
        }

        /// The spaces and tabs between the start of the line and `position`,
        /// when nothing else precedes it on that line.
        private func lineIndent(before position: Int) -> String? {
            var start = position
            while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
            guard start > 0, bytes[start - 1] == 0x0A else { return nil }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        /// A string, quotes included.
        private mutating func string() throws -> Range<Int> {
            let start = index
            try expect(UInt8(ascii: "\""))
            while let byte = peek {
                index += 1
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    return start..<index
                }
            }
            throw Malformed()
        }

        private mutating func value() throws {
            switch peek {
            case UInt8(ascii: "\""):
                _ = try string()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                repeat {
                    switch peek {
                    case UInt8(ascii: "\""):
                        _ = try string()
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                    case nil:
                        throw Malformed()
                    default:
                        break
                    }
                    index += 1
                } while depth > 0
            default:
                // A number, true, false or null.
                while let byte = peek, !Self.isWhitespace(byte), byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"), byte != UInt8(ascii: "]") {
                    index += 1
                }
            }
        }
    }
}
