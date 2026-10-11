import Foundation

/// The latest raw readings from every source. The engine turns these, plus a
/// clock, into a `UsageSnapshot`. A missing reading means "no data".
public struct Readings: Decodable, Equatable, Sendable {
    /// Claude limits from the usage endpoint (today, the bundled sample):
    /// the only source for Fable, and the plan.
    public var claude: ClaudeLimits?
    /// Claude's 5-hour and weekly limits from the status line file, the
    /// live source while Claude Code is in use.
    public var claudeStatusLine: ClaudeLimits?
    /// Codex limits from `codex app-server`, the live source.
    public var codex: CodexLimits?
    /// The latest Codex record in the session logs: the fallback when
    /// app-server isn't available, and fresher whenever another Codex
    /// process ran a turn since app-server last reported.
    public var codexSessionLog: CodexLimits?

    public init(
        claude: ClaudeLimits? = nil,
        claudeStatusLine: ClaudeLimits? = nil,
        codex: CodexLimits? = nil,
        codexSessionLog: CodexLimits? = nil
    ) {
        self.claude = claude
        self.claudeStatusLine = claudeStatusLine
        self.codex = codex
        self.codexSessionLog = codexSessionLog
    }
}

/// One limit window as a source reports it.
public struct LimitReading: Decodable, Equatable, Sendable {
    /// Percent of the window used, 0–100.
    public var usedPercent: Double
    public var resetsAt: Date

    public init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Claude's limit windows: 5-hour session, weekly (all models), weekly Fable.
public struct ClaudeLimits: Decodable, Equatable, Sendable {
    /// Plan name, e.g. "Max".
    public var plan: String?
    /// When the source took the reading; nil when it isn't readable.
    public var capturedAt: Date?
    public var fiveHour: LimitReading?
    public var sevenDay: LimitReading?
    public var sevenDayFable: LimitReading?

    public init(
        plan: String? = nil,
        capturedAt: Date?,
        fiveHour: LimitReading? = nil,
        sevenDay: LimitReading? = nil,
        sevenDayFable: LimitReading? = nil
    ) {
        self.plan = plan
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayFable = sevenDayFable
    }
}

/// Codex's limit windows: zero or more, each with its own length.
public struct CodexLimits: Decodable, Equatable, Sendable {
    /// Plan type as Codex reports it, e.g. "pro".
    public var plan: String?
    /// When the source took the reading; nil when it isn't readable.
    public var capturedAt: Date?
    public var windows: [CodexWindow]

    public init(plan: String? = nil, capturedAt: Date?, windows: [CodexWindow]) {
        self.plan = plan
        self.capturedAt = capturedAt
        self.windows = windows
    }
}

/// One Codex window, identified by its length. `reading` is nil when the
/// window is reported but its numbers can't be read.
public struct CodexWindow: Equatable, Sendable {
    public var windowMinutes: Int
    public var reading: LimitReading?

    public init(windowMinutes: Int, reading: LimitReading?) {
        self.windowMinutes = windowMinutes
        self.reading = reading
    }

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date) {
        self.init(windowMinutes: windowMinutes, reading: LimitReading(usedPercent: usedPercent, resetsAt: resetsAt))
    }
}

// MARK: - Shifting in time

extension Readings {
    func shifted(by offset: TimeInterval) -> Readings {
        Readings(
            claude: claude?.shifted(by: offset),
            claudeStatusLine: claudeStatusLine?.shifted(by: offset),
            codex: codex?.shifted(by: offset),
            codexSessionLog: codexSessionLog?.shifted(by: offset)
        )
    }
}

extension LimitReading {
    func shifted(by offset: TimeInterval) -> LimitReading {
        LimitReading(usedPercent: usedPercent, resetsAt: resetsAt + offset)
    }
}

extension ClaudeLimits {
    func shifted(by offset: TimeInterval) -> ClaudeLimits {
        ClaudeLimits(
            plan: plan,
            capturedAt: capturedAt.map { $0 + offset },
            fiveHour: fiveHour?.shifted(by: offset),
            sevenDay: sevenDay?.shifted(by: offset),
            sevenDayFable: sevenDayFable?.shifted(by: offset)
        )
    }
}

extension CodexLimits {
    func shifted(by offset: TimeInterval) -> CodexLimits {
        CodexLimits(
            plan: plan,
            capturedAt: capturedAt.map { $0 + offset },
            windows: windows.map {
                CodexWindow(windowMinutes: $0.windowMinutes, reading: $0.reading?.shifted(by: offset))
            }
        )
    }
}

// MARK: - Tolerant decoding
//
// Readings come from formats that can change without notice. A missing,
// renamed or mistyped field drops only the row it feeds (which then shows
// "—"); it never fails the whole readings file.

extension Readings {
    private enum CodingKeys: String, CodingKey {
        case claude, claudeStatusLine, codex, codexSessionLog
        /// Recorded status line JSON, run through the status line command
        /// into `claudeStatusLine`.
        case claudeStatusLineInputs
        /// Recorded app-server stdout lines, replayed into `codex`.
        case codexAppServerMessages
        /// Recorded session-log lines, read into `codexSessionLog`.
        case codexSessionLogLines
    }

    /// Recorded app-server messages and the time they arrived.
    private struct RecordedAppServer: Decodable {
        var receivedAt: Date
        var messages: [Lenient<IncomingMessage>]

        /// The reading the app would hold after these messages.
        var limits: CodexLimits? {
            var conversation = CodexAppServerConversation()
            _ = conversation.start()
            return messages.compactMap(\.value).reduce(nil) { latest, message in
                switch conversation.receive(message, at: receivedAt).reading {
                case let .updated(limits): limits
                case .unusable: nil
                case nil: latest
                }
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = try? c.decodeIfPresent(ClaudeLimits.self, forKey: .claude)
        claudeStatusLine = (try? c.decodeIfPresent(ClaudeLimits.self, forKey: .claudeStatusLine))
            ?? (try? c.decodeIfPresent([ClaudeStatusLine.RecordedInput].self, forKey: .claudeStatusLineInputs))
                .flatMap(ClaudeStatusLine.replay)
        codex = (try? c.decodeIfPresent(CodexLimits.self, forKey: .codex))
            ?? (try? c.decodeIfPresent(RecordedAppServer.self, forKey: .codexAppServerMessages))?.limits
        codexSessionLog = (try? c.decodeIfPresent(CodexLimits.self, forKey: .codexSessionLog))
            ?? (try? c.decodeIfPresent([Lenient<CodexSessionLog.Line>].self, forKey: .codexSessionLogLines))
                .flatMap { CodexSessionLog.lastRecord(of: $0.compactMap(\.value))?.limits }
    }
}

extension ClaudeLimits {
    private enum CodingKeys: String, CodingKey {
        case plan, capturedAt, fiveHour, sevenDay, sevenDayFable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
        fiveHour = try? c.decodeIfPresent(LimitReading.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(LimitReading.self, forKey: .sevenDay)
        sevenDayFable = try? c.decodeIfPresent(LimitReading.self, forKey: .sevenDayFable)
    }
}

extension CodexLimits {
    private enum CodingKeys: String, CodingKey {
        case plan, capturedAt, windows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
        windows = ((try? c.decodeIfPresent([Lenient<CodexWindow>].self, forKey: .windows)) ?? [])
            .compactMap(\.value)
    }
}

extension CodexWindow: Decodable {
    private enum CodingKeys: String, CodingKey {
        case windowMinutes, usedPercent, resetsAt
    }

    /// A window whose length is readable keeps its place (so a 5-hour window
    /// with bad numbers shows "—" rather than vanishing); one whose length
    /// isn't readable can't be identified and is dropped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowMinutes = try c.decode(Int.self, forKey: .windowMinutes)
        if let used = try? c.decode(Double.self, forKey: .usedPercent),
           let resetsAt = try? c.decode(Date.self, forKey: .resetsAt) {
            reading = LimitReading(usedPercent: used, resetsAt: resetsAt)
        } else {
            reading = nil
        }
    }
}

/// Decodes a `T`, or nil when that element is malformed, so one bad array
/// element doesn't sink its siblings.
struct Lenient<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
