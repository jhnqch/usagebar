import Foundation

/// Claude Code's status line, the live source for Claude's 5-hour and weekly
/// limits. Claude Code runs UsageBar's status line command after each reply
/// and pipes it the session's JSON. The command saves the `rate_limits` part
/// to a file the app watches, and prints a compact line for the terminal.
///
/// Pure: the command passes in what it read, and writes and prints what
/// `run` returns.
public enum ClaudeStatusLine {
    /// The saved file's name in UsageBar's support directory.
    public static let fileName = "claude-status-line.json"

    /// UsageBar's support directory, shared by the app and the status line
    /// command: `~/Library/Application Support/UsageBar`, or
    /// `$USAGEBAR_SUPPORT_DIR` when set (for trying the command out).
    public static func supportDirectory(environment: [String: String], home: URL) -> URL {
        if let override = environment["USAGEBAR_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appending(path: "Library/Application Support/UsageBar", directoryHint: .isDirectory)
    }

    /// What the command does with one status line JSON from Claude Code.
    public struct Run: Equatable, Sendable {
        /// The line to print.
        public var line: String
        /// The file to save; nil to leave the saved file as it is.
        public var save: Data?
    }

    /// Handles the status line JSON `input` at `now`, given the file the
    /// command saved last (nil when there's none).
    public static func run(input: Data, saved: Data?, now: Date) -> Run {
        let payload = (try? JSONDecoder().decode(Payload.self, from: input)) ?? Payload()
        return run(payload, saved: saved.flatMap(SavedFile.decode), now: now)
    }

    /// Claude's 5-hour and weekly limits as the saved file records them; nil
    /// when the file holds neither.
    public static func limits(fromSaved data: Data) -> ClaudeLimits? {
        SavedFile.decode(data)?.limits
    }

    static func run(_ payload: Payload, saved: SavedFile?, now: Date) -> Run {
        guard payload.hasRateLimits else { return Run(line: payload.model, save: nil) }
        let windows: [(Payload.Window, LimitReading?)] = [(payload.fiveHour, saved?.fiveHour), (payload.sevenDay, saved?.sevenDay)]
        // Every session runs the status line, and an idle one re-runs it (on
        // a mode change, say) with numbers from its last reply. Those are out
        // of date when another session has saved later numbers since.
        let outOfDate = windows.contains { new, old in
            guard case let .reading(new) = new, let old else { return false }
            return !new.supersedes(old, at: now)
        }
        let file = SavedFile(
            capturedAt: outOfDate ? saved?.capturedAt : now,
            fiveHour: merged(payload.fiveHour, saved?.fiveHour, at: now),
            sevenDay: merged(payload.sevenDay, saved?.sevenDay, at: now)
        )
        let unchanged = file == saved || (saved == nil && file.limits == nil)
        return Run(line: line(model: payload.model, file, now: now), save: unchanged ? nil : file.encoded())
    }

    /// A window after this JSON: Claude Code drops a window once it resets,
    /// so a missing one keeps the saved reading (which the app shows at 0%);
    /// one it sent but that can't be read shows as unknown; a reading wins
    /// if it's the later one.
    private static func merged(_ new: Payload.Window, _ old: LimitReading?, at now: Date) -> LimitReading? {
        switch new {
        case .absent: old
        case .unreadable: nil
        case let .reading(new): latest(new, old, at: now)
        }
    }

    /// The later of two readings of a window. Claude Code drops a window
    /// once it resets, so a missing window keeps the saved one, which the
    /// app then shows at 0% rather than as unknown.
    private static func latest(_ new: LimitReading?, _ old: LimitReading?, at now: Date) -> LimitReading? {
        guard let new, let old else { return new ?? old }
        return new.supersedes(old, at: now) ? new : old
    }

    /// `Opus 5.5 · 5h 19% · wk 11%`, with the same reset rule as the app.
    private static func line(model: String, _ file: SavedFile, now: Date) -> String {
        var parts = [model]
        if let fiveHour = file.fiveHour?.current(at: now) {
            parts.append("5h \(UsageEngine.percentText(fiveHour.usedPercent))")
        }
        if let sevenDay = file.sevenDay?.current(at: now) {
            parts.append("wk \(UsageEngine.percentText(sevenDay.usedPercent))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Recorded inputs

extension ClaudeStatusLine {
    /// One recorded run of the status line command: the JSON Claude Code
    /// piped in, and when.
    struct RecordedInput: Decodable {
        var receivedAt: Date
        var payload: Payload
    }

    /// The limits the app would read after the command handled these runs
    /// in order, starting with no saved file.
    static func replay(_ inputs: [RecordedInput]) -> ClaudeLimits? {
        inputs.reduce(nil as SavedFile?) { saved, input in
            run(input.payload, saved: saved, now: input.receivedAt).save.flatMap(SavedFile.decode) ?? saved
        }?.limits
    }
}

// MARK: - Claude Code's status line JSON

extension ClaudeStatusLine {
    /// The parts of Claude Code's status line JSON UsageBar uses: the model's
    /// name and `rate_limits.five_hour` / `rate_limits.seven_day`, each
    /// `{"used_percentage": 0–100, "resets_at": <Unix seconds>}`. Claude Code
    /// sends `rate_limits` only to Pro and Max subscribers, only after the
    /// session's first reply, and drops a window once it resets.
    struct Payload: Decodable {
        var model = "Claude"
        var fiveHour = Window.absent
        var sevenDay = Window.absent

        /// One window in the JSON.
        enum Window: Equatable {
            /// Not sent: no rate limits yet, or dropped after its reset.
            case absent
            /// Sent, but not in a shape UsageBar can read.
            case unreadable
            case reading(LimitReading)
        }

        /// Whether the JSON says anything about the windows.
        var hasRateLimits: Bool { fiveHour != .absent || sevenDay != .absent }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case model
            case rateLimits = "rate_limits"
        }

        private enum WindowKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        private struct Model: Decodable {
            var name: String?

            private enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = [CodingKeys.displayName, .id]
                    .lazy
                    .compactMap { try? c.decodeIfPresent(String.self, forKey: $0) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
            }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let name = (try? c.decodeIfPresent(Model.self, forKey: .model))?.name {
                model = name
            }
            guard c.contains(.rateLimits), (try? c.decodeNil(forKey: .rateLimits)) != true else { return }
            guard let windows = try? c.nestedContainer(keyedBy: WindowKeys.self, forKey: .rateLimits) else {
                // `rate_limits` that isn't an object: neither window can be read.
                (fiveHour, sevenDay) = (.unreadable, .unreadable)
                return
            }
            fiveHour = Self.window(windows, .fiveHour)
            sevenDay = Self.window(windows, .sevenDay)
        }

        private static func window(_ c: KeyedDecodingContainer<WindowKeys>, _ key: WindowKeys) -> Window {
            guard c.contains(key), (try? c.decodeNil(forKey: key)) != true else { return .absent }
            return (try? c.decode(RateLimits.Window.self, forKey: key)).map { .reading($0.reading) } ?? .unreadable
        }
    }

    /// `rate_limits` as the saved file keeps it (Claude Code's shape). A
    /// window that's missing or can't be read is nil.
    struct RateLimits: Codable {
        var fiveHour: LimitReading?
        var sevenDay: LimitReading?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        struct Window: Codable {
            var usedPercentage: Double
            var resetsAt: Double

            private enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }

            var reading: LimitReading {
                LimitReading(usedPercent: usedPercentage, resetsAt: Date(timeIntervalSince1970: resetsAt))
            }

            init(_ reading: LimitReading) {
                usedPercentage = reading.usedPercent
                resetsAt = reading.resetsAt.timeIntervalSince1970
            }
        }

        init(fiveHour: LimitReading?, sevenDay: LimitReading?) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = (try? c.decodeIfPresent(Window.self, forKey: .fiveHour))?.reading
            sevenDay = (try? c.decodeIfPresent(Window.self, forKey: .sevenDay))?.reading
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(fiveHour.map(Window.init), forKey: .fiveHour)
            try c.encodeIfPresent(sevenDay.map(Window.init), forKey: .sevenDay)
        }
    }
}

// MARK: - The saved file

extension ClaudeStatusLine {
    /// What the command saves for the app: the latest known windows in
    /// Claude Code's own `rate_limits` shape, plus when they were captured.
    ///
    /// ```json
    /// {
    ///   "capturedAt" : "2026-10-11T05:45:53Z",
    ///   "rate_limits" : {
    ///     "five_hour" : { "resets_at" : 1791708600, "used_percentage" : 19 },
    ///     "seven_day" : { "resets_at" : 1792134000, "used_percentage" : 11 }
    ///   }
    /// }
    /// ```
    struct SavedFile: Equatable {
        var capturedAt: Date?
        var fiveHour: LimitReading?
        var sevenDay: LimitReading?

        var limits: ClaudeLimits? {
            guard fiveHour != nil || sevenDay != nil else { return nil }
            return ClaudeLimits(capturedAt: capturedAt, fiveHour: fiveHour, sevenDay: sevenDay)
        }

        private struct Raw: Codable {
            var capturedAt: Date?
            var rateLimits: RateLimits?

            private enum CodingKeys: String, CodingKey {
                case capturedAt
                case rateLimits = "rate_limits"
            }

            init(capturedAt: Date?, rateLimits: RateLimits?) {
                self.capturedAt = capturedAt
                self.rateLimits = rateLimits
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
                rateLimits = try? c.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
            }
        }

        static func decode(_ data: Data) -> SavedFile? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let raw = try? decoder.decode(Raw.self, from: data) else { return nil }
            return SavedFile(capturedAt: raw.capturedAt, fiveHour: raw.rateLimits?.fiveHour, sevenDay: raw.rateLimits?.sevenDay)
        }

        func encoded() -> Data? {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let raw = Raw(capturedAt: capturedAt, rateLimits: RateLimits(fiveHour: fiveHour, sevenDay: sevenDay))
            return try? encoder.encode(raw) + Data("\n".utf8)
        }
    }
}

// MARK: - Which reading is later

extension LimitReading {
    /// Resets this close together are the same window: a new 5-hour or
    /// weekly window resets hours or days after the one before.
    private static let sameWindow: TimeInterval = 60 * 60

    /// Whether this reading is at least as recent as `old`, judged by the
    /// numbers alone (a status line JSON doesn't say when it was fetched).
    /// Within a window that's still running, use only goes up; otherwise the
    /// window that resets later is the later one.
    func supersedes(_ old: LimitReading, at now: Date) -> Bool {
        if old.resetsAt > now, abs(resetsAt.timeIntervalSince(old.resetsAt)) < Self.sameWindow {
            return usedPercent >= old.usedPercent
        }
        return resetsAt >= old.resetsAt
    }
}
