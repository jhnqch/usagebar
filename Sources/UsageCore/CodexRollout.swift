import Foundation

/// Codex's rollout files: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, one
/// per thread (a session, or a subagent such as a `codex review` thread),
/// appended to in order. The lines UsageBar reads:
///
/// - `session_meta`: the thread's id.
/// - `turn_context`: the model for the turn that follows.
/// - `event_msg` / `token_count`: after each model response, the thread's
///   running total (`total_token_usage`) and that response's usage
///   (`last_token_usage`). `info` is null before the first response.
///
/// Counts overlap: `cached_input_tokens` and `cache_write_input_tokens` are
/// part of `input_tokens`, and `reasoning_output_tokens` is part of
/// `output_tokens`. A thread's usage is in its own file only: a `codex
/// review` parent thread logs no token counts, its review thread logs its
/// own. Each response also gets a `token_usage_record` line with the same
/// numbers, which isn't read, so nothing counts twice.
///
/// The format is undocumented. A line that can't be read is skipped, never
/// the whole file; a missing count reads as zero.
public enum CodexRollout {
    /// Reads one rollout file in order. Each response's usage is the change
    /// in the running total since the last token count, so a count Codex
    /// sends again adds nothing. Where there's no earlier total (a file's
    /// first count, which may carry usage from before the file), or the
    /// total went down (it started over), the response's own usage counts.
    public struct Parser: UsageLogParser {
        /// Names the file's entries: its thread id once `session_meta` is
        /// read, else its file name. A file read again, or moved (as
        /// archiving does), gives the same ids, so it isn't counted twice.
        private var thread: String
        private var sawMeta = false
        private var model: String?
        private var total: Usage?
        private var responses = 0

        public init(path: String) {
            thread = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }

        public mutating func entries(in lines: Data) -> [UsageEntry] {
            let decoder = JSONDecoder()
            var entries: [UsageEntry] = []
            JSONLines.forEach(in: lines, containingAny: Self.keys) { line in
                if let line = try? decoder.decode(Line.self, from: line), let entry = receive(line) {
                    entries.append(entry)
                }
            }
            return entries
        }

        /// Every line UsageBar reads names one of these. Checking the bytes
        /// first skips decoding the rest, which hold the conversation.
        private static let keys = ["session_meta", "turn_context", "token_count"].map { Data($0.utf8) }

        /// One line's entry, if it ends a response with usage.
        mutating func receive(_ line: Line) -> UsageEntry? {
            switch line.kind {
            case let .sessionMeta(id):
                if !sawMeta, let id {
                    thread = id
                    sawMeta = true
                }
                return nil
            case let .turnContext(model):
                if let model { self.model = model }
                return nil
            case let .tokenCount(total, last):
                let usage: Usage?
                if let total {
                    if let previous = self.total, total.sum >= previous.sum {
                        usage = total.since(previous)
                    } else {
                        usage = last ?? total
                    }
                    self.total = total
                } else {
                    usage = last
                }
                guard let usage, usage.sum > 0, let timestamp = line.timestamp else { return nil }
                defer { responses += 1 }
                return UsageEntry(
                    id: "\(thread)#\(responses)",
                    timestamp: timestamp,
                    model: model ?? "unknown",
                    tokens: usage.tokens
                )
            case .other:
                return nil
            }
        }
    }

    /// Token counts as Codex logs them.
    struct Usage: Equatable, Sendable, Decodable {
        /// Every input token, cached or not.
        var input: Int
        /// Input read from the cache.
        var cached: Int
        /// Input written to the cache.
        var cacheWrite: Int
        /// Every output token, reasoning included.
        var output: Int

        /// Every token, as `total_tokens` would say.
        var sum: Int { input + output }

        /// The change since `earlier`, field by field, never below zero.
        func since(_ earlier: Usage) -> Usage {
            Usage(
                input: max(0, input - earlier.input),
                cached: max(0, cached - earlier.cached),
                cacheWrite: max(0, cacheWrite - earlier.cacheWrite),
                output: max(0, output - earlier.output)
            )
        }

        /// By how they're priced: uncached input, cache writes, cache reads
        /// and output. Codex has one cache, so its writes go in the
        /// 5-minute slot.
        var tokens: TokenCounts {
            TokenCounts(
                input: max(0, input - cached - cacheWrite),
                cacheWrite5m: cacheWrite,
                cacheRead: cached,
                output: output
            )
        }

        private enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case cached = "cached_input_tokens"
            case cacheWrite = "cache_write_input_tokens"
            case output = "output_tokens"
        }

        init(input: Int, cached: Int, cacheWrite: Int, output: Int) {
            self.input = input
            self.cached = cached
            self.cacheWrite = cacheWrite
            self.output = output
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = tokenCount(c, .input)
            cached = tokenCount(c, .cached)
            cacheWrite = tokenCount(c, .cacheWrite)
            output = tokenCount(c, .output)
        }
    }

    /// One rollout line, as far as usage goes.
    struct Line: Decodable {
        enum Kind {
            case sessionMeta(id: String?)
            case turnContext(model: String?)
            case tokenCount(total: Usage?, last: Usage?)
            case other
        }

        var timestamp: Date?
        var kind: Kind

        private enum CodingKeys: String, CodingKey {
            case timestamp, type, payload
        }

        private enum PayloadKeys: String, CodingKey {
            case id, model, type, info
        }

        private enum InfoKeys: String, CodingKey {
            case total = "total_token_usage"
            case last = "last_token_usage"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)).flatMap(JSONLines.date)
            let payload = try? c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            switch try? c.decodeIfPresent(String.self, forKey: .type) {
            case "session_meta"?:
                kind = .sessionMeta(id: try? payload?.decodeIfPresent(String.self, forKey: .id))
            case "turn_context"?:
                kind = .turnContext(model: try? payload?.decodeIfPresent(String.self, forKey: .model))
            case "event_msg"? where (try? payload?.decodeIfPresent(String.self, forKey: .type)) == "token_count":
                // `info` is null until the first response.
                guard let info = try? payload?.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) else {
                    kind = .other
                    return
                }
                kind = .tokenCount(
                    total: try? info.decodeIfPresent(Usage.self, forKey: .total),
                    last: try? info.decodeIfPresent(Usage.self, forKey: .last)
                )
            default:
                kind = .other
            }
        }
    }
}
