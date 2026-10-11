import Foundation

/// The fallback Codex source: the rate-limit records Codex writes into its
/// session logs (`~/.codex/sessions/YYYY/MM/DD/*.jsonl`) after each turn.
public enum CodexSessionLog {
    /// One Codex rate-limit record.
    public struct Record: Equatable, Sendable {
        /// When Codex wrote it; nil when the timestamp can't be read.
        public var capturedAt: Date?
        /// Its limits; nil when the record can't be read (a changed format,
        /// say), which makes any older reading stale too.
        public var limits: CodexLimits?
    }

    /// The last Codex rate-limit record in a log (one JSON object per line),
    /// or nil when there's none. Codex appends lines in order, so the last
    /// one is the latest, whatever its timestamp says. Lines that aren't
    /// Codex rate-limit records are skipped, including a partial first
    /// line from reading a file's tail.
    public static func lastRecord(in log: Data) -> Record? {
        let decoder = JSONDecoder()
        let lines = log.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(Line.self, from: Data($0))
        }
        return lastRecord(of: lines)
    }

    static func lastRecord(of lines: [Line]) -> Record? {
        lines.last { $0.record != nil }?.record
    }

    /// One session-log line. Only `event_msg` lines whose payload is a
    /// `token_count` with `rate_limits` for the main `codex` bucket are
    /// records.
    struct Line: Decodable {
        var record: Record?

        private enum CodingKeys: String, CodingKey {
            case timestamp, type, payload
        }

        private struct Payload: Decodable {
            var isTokenCount: Bool
            /// nil when there are no rate limits; `.failure` when they're
            /// there but can't be read.
            var rateLimits: Result<RateLimits, any Error>?

            private enum CodingKeys: String, CodingKey {
                case type
                case rateLimits = "rate_limits"
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                isTokenCount = (try? c.decodeIfPresent(String.self, forKey: .type)) == "token_count"
                if c.contains(.rateLimits), (try? c.decodeNil(forKey: .rateLimits)) == false {
                    rateLimits = Result { try c.decode(RateLimits.self, forKey: .rateLimits) }
                }
            }
        }

        private struct RateLimits: Decodable {
            var limitID: String?
            var planType: String?
            var primary: RateLimitWindow?
            var secondary: RateLimitWindow?

            private enum CodingKeys: String, CodingKey {
                case limitID = "limit_id"
                case planType = "plan_type"
                case primary, secondary
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                limitID = try? c.decodeIfPresent(String.self, forKey: .limitID)
                planType = try? c.decodeIfPresent(String.self, forKey: .planType)
                primary = try? c.decodeIfPresent(RateLimitWindow.SessionLog.self, forKey: .primary)?.window
                secondary = try? c.decodeIfPresent(RateLimitWindow.SessionLog.self, forKey: .secondary)?.window
            }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard
                (try? c.decodeIfPresent(String.self, forKey: .type)) == "event_msg",
                let payload = try? c.decodeIfPresent(Payload.self, forKey: .payload),
                payload.isTokenCount,
                let rateLimits = payload.rateLimits
            else { return }
            let timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)).flatMap(Self.date)
            switch rateLimits {
            case let .success(rateLimits):
                // Another bucket (a per-model quota, say) isn't about these meters.
                guard rateLimits.limitID == nil || rateLimits.limitID == "codex" else { return }
                record = Record(
                    capturedAt: timestamp,
                    limits: RateLimitWindow.codexLimits(
                        limitID: rateLimits.limitID,
                        plan: rateLimits.planType,
                        windows: [rateLimits.primary, rateLimits.secondary],
                        capturedAt: timestamp
                    )
                )
            case .failure:
                record = Record(capturedAt: timestamp, limits: nil)
            }
        }

        /// Session-log timestamps carry milliseconds: "2026-10-10T20:22:28.809Z".
        private static func date(_ text: String) -> Date? {
            (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(text, strategy: .iso8601))
        }
    }
}
