import Foundation

/// Claude Code's transcripts: `~/.claude/projects/<project>/<session>.jsonl`,
/// plus each subagent's under `<session>/subagents/`. Every assistant line
/// carries its message's id, model and token usage.
///
/// The format is undocumented. A line that can't be read is skipped, never
/// the whole file; a missing count reads as zero.
public enum ClaudeTranscript {
    /// The replies' usage in a run of transcript lines (one JSON object per
    /// line). Lines that aren't model replies with usage are skipped,
    /// including Claude Code's `<synthetic>` placeholders and a cut-off line.
    /// The same reply can appear more than once; `UsageLedger` merges them.
    public static func entries(in log: Data) -> [UsageEntry] {
        let decoder = JSONDecoder()
        var entries: [UsageEntry] = []
        log.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            usageKey.withUnsafeBytes { (key: UnsafeRawBufferPointer) in
                var start = 0
                while start < raw.count {
                    let line = base + start
                    var end = raw.count
                    if let newline = memchr(line, 0x0A, raw.count - start) {
                        end = start + (UnsafeRawPointer(newline) - line)
                    }
                    // Only assistant lines carry `"usage"`. Checking the bytes
                    // first skips decoding the user lines, which hold the
                    // (much larger) tool results.
                    let length = end - start
                    if length > 0, memmem(line, length, key.baseAddress, key.count) != nil,
                       let decoded = try? decoder.decode(Line.self, from: Data(bytes: line, count: length)),
                       let entry = decoded.entry {
                        entries.append(entry)
                    }
                    start = end + 1
                }
            }
        }
        return entries
    }

    private static let usageKey = Data(#""usage""#.utf8)

    /// One transcript line; `entry` is nil unless it's a model reply with usage.
    struct Line: Decodable {
        var entry: UsageEntry?

        private enum CodingKeys: String, CodingKey {
            case type, timestamp, requestId, message
        }

        private struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: Usage?

            private enum CodingKeys: String, CodingKey { case id, model, usage }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                model = try? c.decodeIfPresent(String.self, forKey: .model)
                usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
            }
        }

        private struct Usage: Decodable {
            var tokens: TokenCounts
            var fast: Bool
            var usOnly: Bool

            private enum CodingKeys: String, CodingKey {
                case input = "input_tokens"
                case cacheCreation = "cache_creation_input_tokens"
                case cacheRead = "cache_read_input_tokens"
                case output = "output_tokens"
                case split = "cache_creation"
                case speed
                case inferenceGeo = "inference_geo"
            }

            private struct Split: Decodable {
                var fiveMinutes: Int
                var oneHour: Int

                private enum CodingKeys: String, CodingKey {
                    case fiveMinutes = "ephemeral_5m_input_tokens"
                    case oneHour = "ephemeral_1h_input_tokens"
                }

                init(from decoder: any Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    fiveMinutes = count(c, .fiveMinutes)
                    oneHour = count(c, .oneHour)
                }
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let split = try? c.decodeIfPresent(Split.self, forKey: .split)
                let written = count(c, .cacheCreation)
                let fiveMinutes = split?.fiveMinutes ?? 0
                let oneHour = split?.oneHour ?? 0
                tokens = TokenCounts(
                    input: count(c, .input),
                    // Writes the split doesn't account for are priced as the
                    // API's default, the 5-minute cache.
                    cacheWrite5m: fiveMinutes + max(0, written - fiveMinutes - oneHour),
                    cacheWrite1h: oneHour,
                    cacheRead: count(c, .cacheRead),
                    output: count(c, .output)
                )
                fast = (try? c.decodeIfPresent(String.self, forKey: .speed)) == "fast"
                usOnly = (try? c.decodeIfPresent(String.self, forKey: .inferenceGeo)) == "us"
            }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard
                (try? c.decodeIfPresent(String.self, forKey: .type)) == "assistant",
                let message = try? c.decodeIfPresent(Message.self, forKey: .message),
                let usage = message.usage, usage.tokens.total > 0,
                message.model != "<synthetic>",
                // Without an id the reply's streamed copies can't be merged.
                let id = message.id ?? (try? c.decodeIfPresent(String.self, forKey: .requestId)),
                let timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)).flatMap(Self.date)
            else { return }
            entry = UsageEntry(
                id: id,
                timestamp: timestamp,
                model: message.model ?? "unknown",
                tokens: usage.tokens,
                fast: usage.fast,
                usOnly: usage.usOnly
            )
        }

        /// Transcript timestamps carry milliseconds: "2026-10-09T22:20:44.544Z".
        private static func date(_ text: String) -> Date? {
            (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(text, strategy: .iso8601))
        }
    }
}

/// A token count, or 0 when it's missing or not a non-negative whole number.
private func count<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int {
    max(0, (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0)
}

/// An incremental scan of transcript files. Claude Code only appends to
/// them, so each file keeps a cursor: the end of its last complete line
/// read. A rescan reads only the bytes after it. The adapter lists the
/// files, asks `reads(for:since:)` what to read, and hands each read's bytes
/// to `receive(_:for:)`.
public struct TranscriptScan: Equatable, Sendable {
    /// A transcript file as listed.
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
    }

    private var cursors: [String: Cursor] = [:]
    private var ledger = UsageLedger()
    private var since = Date.distantPast

    public init() {}

    /// What to read now, given the transcript files that exist and the
    /// earliest time still wanted. A file last changed before `since` holds
    /// nothing newer, so it isn't read; replies before it are forgotten.
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
            // New, replaced or shrunk: from the start. Replies already
            // counted are merged by message id, not counted twice.
            guard file.modified >= since || cursors[file.path] != nil else { continue }
            cursors[file.path] = Cursor(identity: file.identity, offset: 0)
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
        ledger.add(ClaudeTranscript.entries(in: Data(complete)).filter { $0.timestamp >= since })
        cursor.offset += complete.count
        cursors[read.path] = cursor
    }

    /// Every reply read so far since `since`, oldest first.
    public var entries: [UsageEntry] { ledger.entries }
}
