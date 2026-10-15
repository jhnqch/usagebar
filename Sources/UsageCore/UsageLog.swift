import Foundation

/// Token counts for one message, by how they're priced.
public struct TokenCounts: Equatable, Sendable {
    /// Uncached input.
    public var input: Int
    /// Input written to the 5-minute prompt cache.
    public var cacheWrite5m: Int
    /// Input written to the 1-hour prompt cache (priced higher).
    public var cacheWrite1h: Int
    /// Input read from the prompt cache.
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    /// Every token, cache reads included.
    public var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    /// The prompt's length: every input token, cached or not.
    public var prompt: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }

    /// Each count's larger value: a streamed message is logged several times
    /// as it grows, so the largest count is the final one. The cache writes
    /// are one total split two ways, so they come as a pair from one copy:
    /// the one with more writes or, for the same writes, more of them
    /// 1-hour (a copy without the split reads them all as 5-minute).
    func merged(with other: TokenCounts) -> TokenCounts {
        let writes = (cacheWrite5m + cacheWrite1h, cacheWrite1h) >= (other.cacheWrite5m + other.cacheWrite1h, other.cacheWrite1h)
            ? self : other
        return TokenCounts(
            input: max(input, other.input),
            cacheWrite5m: writes.cacheWrite5m,
            cacheWrite1h: writes.cacheWrite1h,
            cacheRead: max(cacheRead, other.cacheRead),
            output: max(output, other.output)
        )
    }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output
        )
    }
}

/// One model reply's usage, from a local log.
public struct UsageEntry: Equatable, Sendable {
    /// The message id that identifies the reply across log lines and files.
    public var id: String
    public var timestamp: Date
    /// The model id as logged, e.g. "claude-opus-5-5".
    public var model: String
    public var tokens: TokenCounts
    /// Whether it ran in fast mode, which is priced higher.
    public var fast: Bool
    /// Whether it ran with US-only inference, which costs 1.1x.
    public var usOnly: Bool

    public init(id: String, timestamp: Date, model: String, tokens: TokenCounts, fast: Bool = false, usOnly: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.fast = fast
        self.usOnly = usOnly
    }

    func shifted(by offset: TimeInterval) -> UsageEntry {
        var copy = self
        copy.timestamp += offset
        return copy
    }
}

/// Usage entries de-duplicated by message id. Claude Code logs a reply once
/// per content block while it streams, each line carrying the usage so far,
/// and a resumed or forked session copies earlier replies into a new file.
/// Each reply counts once, with its final (largest) counts, at the time it
/// was first logged.
public struct UsageLedger: Equatable, Sendable {
    private var byID: [String: UsageEntry] = [:]

    public init() {}

    public mutating func add(_ entry: UsageEntry) {
        guard let known = byID[entry.id] else {
            byID[entry.id] = entry
            return
        }
        byID[entry.id] = UsageEntry(
            id: entry.id,
            timestamp: min(known.timestamp, entry.timestamp),
            model: known.model,
            tokens: known.tokens.merged(with: entry.tokens),
            fast: known.fast || entry.fast,
            usOnly: known.usOnly || entry.usOnly
        )
    }

    public mutating func add(_ entries: [UsageEntry]) {
        for entry in entries { add(entry) }
    }

    /// Forgets replies logged before `date`.
    public mutating func removeEntries(before date: Date) {
        byID = byID.filter { $0.value.timestamp >= date }
    }

    /// Every reply, oldest first.
    public var entries: [UsageEntry] {
        byID.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
    }

    public var count: Int { byID.count }
}

/// Reads one kind of usage log, a file at a time, for `UsageLogScan`. A
/// parser is made for each file and sees its complete lines in order, so it
/// can carry what earlier lines said (a Codex turn's model, say) to later
/// ones.
public protocol UsageLogParser: Equatable, Sendable {
    /// A parser for the file at `path`, before its first line.
    init(path: String)
    /// The usage in the file's next complete lines.
    mutating func entries(in lines: Data) -> [UsageEntry]
}

/// An incremental scan of usage logs. Claude Code and Codex only append to
/// them, so each file keeps a cursor: the end of its last complete line read,
/// and its parser as of that line. A rescan reads only the bytes after it.
/// The adapter lists the files, asks `reads(for:since:)` what to read, and
/// hands each read's bytes to `receive(_:for:)`.
public struct UsageLogScan<Parser: UsageLogParser>: Equatable, Sendable {
    /// A log file as listed.
    public struct File: Equatable, Sendable {
        public var path: String
        public var size: Int
        public var modified: Date
        /// The file's identity (its inode): a new file under the same name
        /// is read from the start.
        public var identity: UInt64

        public init(path: String, size: Int, modified: Date, identity: UInt64) {
            self.path = path
            self.size = size
            self.modified = modified
            self.identity = identity
        }
    }

    /// Bytes to read from a file.
    public struct Read: Equatable, Sendable {
        public var path: String
        public var offset: Int
        public var length: Int

        public init(path: String, offset: Int, length: Int) {
            self.path = path
            self.offset = offset
            self.length = length
        }
    }

    private struct Cursor: Equatable, Sendable {
        var identity: UInt64
        var offset: Int
        var parser: Parser
    }

    private var cursors: [String: Cursor] = [:]
    private var ledger = UsageLedger()
    private var since = Date.distantPast

    public init() {}

    /// What to read now, given the log files that exist and the earliest
    /// time still wanted. A file last changed before `since` holds nothing
    /// newer, so it isn't read; usage before it is forgotten.
    public mutating func reads(for files: [File], since: Date) -> [Read] {
        self.since = since
        ledger.removeEntries(before: since)
        let listed = Set(files.map(\.path))
        cursors = cursors.filter { listed.contains($0.key) }
        var reads: [Read] = []
        for file in files {
            if let cursor = cursors[file.path], cursor.identity == file.identity, cursor.offset <= file.size {
                if cursor.offset < file.size {
                    reads.append(Read(path: file.path, offset: cursor.offset, length: file.size - cursor.offset))
                }
                continue
            }
            // New, replaced or shrunk: from the start, with a fresh parser.
            // Usage already counted is merged by id, not counted twice.
            guard file.modified >= since || cursors[file.path] != nil else { continue }
            cursors[file.path] = Cursor(identity: file.identity, offset: 0, parser: Parser(path: file.path))
            if file.size > 0 {
                reads.append(Read(path: file.path, offset: 0, length: file.size))
            }
        }
        return reads
    }

    /// The bytes read for `read`. Takes every complete line; a last line
    /// still being written is read again next time.
    public mutating func receive(_ bytes: Data, for read: Read) {
        guard var cursor = cursors[read.path], cursor.offset == read.offset,
              let lastNewline = bytes.lastIndex(of: UInt8(ascii: "\n"))
        else { return }
        let complete = bytes[bytes.startIndex...lastNewline]
        ledger.add(cursor.parser.entries(in: Data(complete)).filter { $0.timestamp >= since })
        cursor.offset += complete.count
        cursors[read.path] = cursor
    }

    /// Every usage entry read so far since `since`, oldest first.
    public var entries: [UsageEntry] { ledger.entries }
}

/// JSON-lines logs: one JSON object per line.
enum JSONLines {
    /// Calls `body` with each line (without its newline) that contains any
    /// of `keys`. The byte check runs before any decoding, so lines that
    /// can't matter, often the biggest, are never decoded.
    static func forEach(in log: Data, containingAny keys: [Data], _ body: (Data) -> Void) {
        log.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                let line = base + start
                var end = raw.count
                if let newline = memchr(line, 0x0A, raw.count - start) {
                    end = start + (UnsafeRawPointer(newline) - line)
                }
                let length = end - start
                if length > 0, keys.contains(where: { key in
                    key.withUnsafeBytes { memmem(line, length, $0.baseAddress, $0.count) != nil }
                }) {
                    body(Data(bytes: line, count: length))
                }
                start = end + 1
            }
        }
    }

    /// Log timestamps, with or without fractional seconds:
    /// "2026-10-09T22:20:44.544Z".
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}
