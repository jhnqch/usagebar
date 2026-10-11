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
        // Only assistant lines carry `"usage"`. Checking the bytes first
        // skips decoding the user lines, which hold the (much larger) tool
        // results.
        JSONLines.forEach(in: log, containingAny: [usageKey]) { line in
            if let entry = (try? decoder.decode(Line.self, from: line))?.entry {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Reads a transcript file for `UsageLogScan`. Each line stands alone,
    /// so there's nothing to carry from one read to the next.
    public struct Parser: UsageLogParser {
        public init(path: String) {}

        public mutating func entries(in lines: Data) -> [UsageEntry] {
            ClaudeTranscript.entries(in: lines)
        }
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
                    fiveMinutes = tokenCount(c, .fiveMinutes)
                    oneHour = tokenCount(c, .oneHour)
                }
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let split = try? c.decodeIfPresent(Split.self, forKey: .split)
                let written = tokenCount(c, .cacheCreation)
                let fiveMinutes = split?.fiveMinutes ?? 0
                let oneHour = split?.oneHour ?? 0
                tokens = TokenCounts(
                    input: tokenCount(c, .input),
                    // Writes the split doesn't account for are priced as the
                    // API's default, the 5-minute cache.
                    cacheWrite5m: fiveMinutes + max(0, written - fiveMinutes - oneHour),
                    cacheWrite1h: oneHour,
                    cacheRead: tokenCount(c, .cacheRead),
                    output: tokenCount(c, .output)
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
func tokenCount<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int {
    max(0, (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0)
}
