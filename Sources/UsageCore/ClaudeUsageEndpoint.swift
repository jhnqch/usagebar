import Foundation

/// Claude's OAuth usage endpoint (undocumented), the only source for the
/// Fable weekly limit. It's server-side, so its 5-hour and weekly numbers
/// include use from the Claude desktop app and claude.ai too.
///
/// `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's saved
/// access token. Pure: the app's adapter makes the request and passes the
/// response in.
public enum ClaudeUsageEndpoint {
    /// Claude's limits in a response body received at `capturedAt`; nil
    /// when no window in it can be read (an error body, a changed format).
    /// A window that can't be read is nil, so only its meter shows "—".
    public static func limits(fromResponse data: Data, capturedAt: Date) -> ClaudeLimits? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        // The flat windows carry decimals; `limits[]` is the newer list that
        // may replace them, so it stands in for any that are missing.
        let limits = ClaudeLimits(
            capturedAt: capturedAt,
            fiveHour: response.fiveHour?.reading ?? response.limit(kind: "session")?.reading,
            sevenDay: response.sevenDay?.reading ?? response.limit(kind: "weekly_all")?.reading,
            sevenDayFable: response.limits.first { $0.isFableWeekly && $0.reading != nil }?.reading ?? response.sevenDayFable?.reading
        )
        let readable = limits.fiveHour != nil || limits.sevenDay != nil || limits.sevenDayFable != nil
        return readable ? limits : nil
    }
}

// MARK: - The response

extension ClaudeUsageEndpoint {
    /// The parts of the response UsageBar uses:
    ///
    /// ```json
    /// {
    ///   "five_hour": { "utilization": 26.0, "resets_at": "2026-10-11T08:49:59.820801+00:00", … },
    ///   "seven_day": { "utilization": 12.0, "resets_at": "2026-10-16T06:59:59.820830+00:00", … },
    ///   "limits": [
    ///     { "kind": "weekly_scoped", "group": "weekly", "percent": 0,
    ///       "resets_at": "2026-10-16T07:00:00+00:00",
    ///       "scope": { "model": { "id": null, "display_name": "Fable" } }, … }
    ///   ]
    /// }
    /// ```
    struct Response: Decodable {
        var fiveHour: Window?
        var sevenDay: Window?
        /// A flat per-model weekly window for Fable (`seven_day_fable`), the
        /// shape per-model windows had before `limits[]`.
        var sevenDayFable: Window?
        var limits: [Limit] = []

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }

        /// The first readable entry of this kind that isn't scoped to a model.
        func limit(kind: String) -> Limit? {
            limits.first { $0.kind == kind && $0.model == nil && $0.reading != nil }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
            limits = ((try? c.decodeIfPresent([Lenient<Limit>].self, forKey: .limits)) ?? []).compactMap(\.value)
            let any = try decoder.container(keyedBy: AnyKey.self)
            sevenDayFable = any.allKeys
                .filter { $0.stringValue.hasPrefix("seven_day_") && $0.stringValue.localizedCaseInsensitiveContains("fable") }
                .lazy
                .compactMap { try? any.decodeIfPresent(Window.self, forKey: $0) }
                .first
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// A flat window: `{"utilization": 0–100, "resets_at": ISO 8601}`.
    struct Window: Decodable {
        var reading: LimitReading

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reading = LimitReading(
                usedPercent: try c.decode(Double.self, forKey: .utilization),
                resetsAt: try c.decodeTimestamp(forKey: .resetsAt)
            )
        }
    }

    /// An entry in `limits[]`.
    struct Limit: Decodable {
        var kind: String?
        var model: String?
        var reading: LimitReading?

        var isFableWeekly: Bool {
            kind == "weekly_scoped" && model?.localizedCaseInsensitiveContains("fable") == true
        }

        private enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }

        private enum ScopeKeys: String, CodingKey { case model }
        private enum ModelKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            let model = try? c.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
                .nestedContainer(keyedBy: ModelKeys.self, forKey: .model)
            self.model = [ModelKeys.displayName, .id].lazy
                .compactMap { key in model.flatMap { try? $0.decodeIfPresent(String.self, forKey: key) } }
                .first
            if let percent = try? c.decode(Double.self, forKey: .percent),
               let resetsAt = try? c.decodeTimestamp(forKey: .resetsAt) {
                reading = LimitReading(usedPercent: percent, resetsAt: resetsAt)
            }
        }
    }
}

extension KeyedDecodingContainer {
    /// An ISO 8601 time with or without fractional seconds, rounded to the
    /// whole second. The endpoint puts resets a hair before the hour
    /// (`06:59:59.820830+00:00`) where the status line says `07:00:00`.
    func decodeTimestamp(forKey key: Key) throws -> Date {
        let text = try decode(String.self, forKey: key)
        guard let parsed = try? Date(text, strategy: .iso8601) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not an ISO 8601 time")
        }
        return Date(timeIntervalSince1970: parsed.timeIntervalSince1970.rounded())
    }
}
