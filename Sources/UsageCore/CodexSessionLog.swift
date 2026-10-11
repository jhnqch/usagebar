import Foundation

/// The fallback Codex source: the rate-limit records Codex writes into its
/// session logs (`~/.codex/sessions/YYYY/MM/DD/*.jsonl`) after each turn.
public enum CodexSessionLog {
    /// The latest Codex reading among session-log lines (one JSON object
    /// per line). Lines that aren't rate-limit records, or can't be read,
    /// are skipped; so is a partial first line from reading a file's tail.
    public static func latestLimits(in log: Data) -> CodexLimits? {
        let decoder = JSONDecoder()
        let lines = log.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(Line.self, from: Data($0))
        }
        return latest(of: lines)
    }

    static func latest(of lines: [Line]) -> CodexLimits? {
        var best: CodexLimits?
        for line in lines {
            guard let limits = line.limits else { continue }
            if (limits.capturedAt ?? .distantPast) >= (best?.capturedAt ?? .distantPast) {
                best = limits
            }
        }
        return best
    }

    /// One session-log line. Only `event_msg` lines whose payload is a
    /// `token_count` with `rate_limits` carry a reading.
    struct Line: Decodable {
        var limits: CodexLimits?

        private enum CodingKeys: String, CodingKey {
            case timestamp, type, payload
        }

        private struct Payload: Decodable {
            var type: String?
            var rateLimits: RateLimits?

            private enum CodingKeys: String, CodingKey {
                case type
                case rateLimits = "rate_limits"
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try? c.decodeIfPresent(String.self, forKey: .type)
                rateLimits = try? c.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
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
                payload.type == "token_count",
                let rateLimits = payload.rateLimits
            else { return }
            let timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)).flatMap(Self.date)
            limits = RateLimitWindow.codexLimits(
                limitID: rateLimits.limitID,
                plan: rateLimits.planType,
                windows: [rateLimits.primary, rateLimits.secondary],
                capturedAt: timestamp
            )
        }

        /// Session-log timestamps carry milliseconds: "2026-10-10T20:22:28.809Z".
        private static func date(_ text: String) -> Date? {
            (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(text, strategy: .iso8601))
        }
    }
}
