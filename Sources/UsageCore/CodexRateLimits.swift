import Foundation

/// One Codex limit window as either source reports it, before it becomes a
/// `CodexWindow`. Each field is nil when it's missing or unreadable.
struct RateLimitWindow {
    var usedPercent: Double?
    var minutes: Int?
    var resetsAt: Date?

    /// app-server's shape: `{"usedPercent", "windowDurationMins", "resetsAt"}`.
    struct AppServer: Decodable {
        var window: RateLimitWindow

        private enum CodingKeys: String, CodingKey {
            case usedPercent, windowDurationMins, resetsAt
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            window = RateLimitWindow(
                usedPercent: try? c.decodeIfPresent(Double.self, forKey: .usedPercent),
                minutes: c.wholeNumber(forKey: .windowDurationMins),
                resetsAt: c.epochSeconds(forKey: .resetsAt)
            )
        }
    }

    /// Codex session logs' shape: `{"used_percent", "window_minutes", "resets_at"}`.
    struct SessionLog: Decodable {
        var window: RateLimitWindow

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            window = RateLimitWindow(
                usedPercent: try? c.decodeIfPresent(Double.self, forKey: .usedPercent),
                minutes: c.wholeNumber(forKey: .windowMinutes),
                resetsAt: c.epochSeconds(forKey: .resetsAt)
            )
        }
    }

    /// Codex limits from a source's windows. Windows are identified by their
    /// length, never by slot: on some plans `primary` is the weekly window.
    /// Only the main `codex` bucket feeds the meters; another bucket (a
    /// per-model quota, say) gives nil. Nil too when no window can be
    /// identified, so the other source can stand in.
    static func codexLimits(limitID: String?, plan: String?, windows: [RateLimitWindow?], capturedAt: Date?) -> CodexLimits? {
        guard limitID == nil || limitID == "codex" else { return nil }
        var seen = Set<Int>()
        var result: [CodexWindow] = []
        for case let window? in windows {
            guard let minutes = window.minutes, minutes > 0, seen.insert(minutes).inserted else { continue }
            var reading: LimitReading?
            if let used = window.usedPercent, let resetsAt = window.resetsAt {
                reading = LimitReading(usedPercent: used, resetsAt: resetsAt)
            }
            result.append(CodexWindow(windowMinutes: minutes, reading: reading))
        }
        guard !result.isEmpty else { return nil }
        return CodexLimits(plan: plan, capturedAt: capturedAt, windows: result)
    }
}

extension KeyedDecodingContainer {
    /// A whole number, whether written `10080` or `10080.0`; nil otherwise.
    func wholeNumber(forKey key: Key) -> Int? {
        (try? decodeIfPresent(Double.self, forKey: key)).flatMap { $0.flatMap { Int(exactly: $0) } }
    }

    /// A Unix time in seconds; nil when missing or not a number.
    func epochSeconds(forKey key: Key) -> Date? {
        (try? decodeIfPresent(Double.self, forKey: key)).flatMap { $0.map { Date(timeIntervalSince1970: $0) } }
    }
}
