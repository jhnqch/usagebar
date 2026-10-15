import Foundation

/// Codex: its limit windows from `codex app-server` or the session logs, and
/// its cost from the rollout files.
public struct CodexProvider: Provider {
    public var id: String { "codex" }
    public var name: String { "Codex" }
    public var symbol: String { "⌘" }
    public var systemImage: String { "apple.terminal" }

    /// Codex limits from `codex app-server`, the live source.
    public var appServer: CodexLimits?
    /// The latest Codex record in the session logs: the fallback when
    /// app-server isn't available, and fresher whenever another Codex
    /// process ran a turn since app-server last reported.
    public var sessionLog: CodexLimits?
    /// Codex's responses from its rollout files, one per response: the
    /// Codex cost chart.
    public var usage: [UsageEntry]

    public init(appServer: CodexLimits? = nil, sessionLog: CodexLimits? = nil, usage: [UsageEntry] = []) {
        self.appServer = appServer
        self.sessionLog = sessionLog
        self.usage = usage
    }

    /// A weekly window's length, as Codex reports it.
    private static let weekMinutes = 7 * 24 * 60
    private static let fiveHourMinutes = 5 * 60

    public func report(clock: Clock) -> ProviderReport {
        let codex = fresher(appServer, sessionLog)
        var windows = (codex?.windows ?? [])
            .sorted { $0.windowMinutes < $1.windowMinutes }
            .map { Self.window($0.windowMinutes, reading: $0.reading) }
        let hasFiveHour = windows.contains { $0.minutes == Self.fiveHourMinutes }
        // Windows are known by their length: on some plans the weekly one
        // comes in the primary slot.
        let weekly = codex?.windows.first { $0.windowMinutes == Self.weekMinutes }?.reading
        if windows.isEmpty {
            windows = [Self.window(Self.weekMinutes, reading: nil)]
        }
        return ProviderReport(
            plan: codex?.plan.map(Self.planBadge),
            updatedAt: codex?.capturedAt,
            rows: windows.map { .window($0) },
            note: codex == nil || hasFiveHour || codex?.windows.isEmpty == true ? nil : "No 5-hour limit on your plan",
            chart: UsageCost.weeklyChart(usage, weekly: weekly, clock: clock, prices: .codex)
        )
    }

    /// Whichever reading was taken later; app-server on a tie.
    private func fresher(_ appServer: CodexLimits?, _ sessionLog: CodexLimits?) -> CodexLimits? {
        guard let appServer, let sessionLog else { return appServer ?? sessionLog }
        return (sessionLog.capturedAt ?? .distantPast) > (appServer.capturedAt ?? .distantPast) ? sessionLog : appServer
    }

    /// A window of `minutes`, labelled and named for alerts by its length.
    private static func window(_ minutes: Int, reading: LimitReading?) -> LimitWindow {
        let label = label(forWindowMinutes: minutes)
        let names: (near: String?, limit: String) = switch minutes {
        case fiveHourMinutes: ("Codex 5-hour session", "Codex 5-hour limit")
        case weekMinutes: (nil, "Codex weekly limit")
        default: (nil, "Codex \(label) limit")
        }
        return LimitWindow(
            id: "codex.\(minutes)m", label: label, minutes: minutes, reading: reading,
            alertName: names.limit, nearAlertName: names.near
        )
    }

    private static func label(forWindowMinutes minutes: Int) -> String {
        switch minutes {
        case fiveHourMinutes: "5-hour session"
        case weekMinutes: "Weekly"
        case let m where m % 1440 == 0: "\(m / 1440)-day"
        case let m where m % 60 == 0: "\(m / 60)-hour"
        case let m: "\(m)-minute"
        }
    }

    /// Codex reports plan ids ("prolite", "edu_plus"); show them as names.
    private static func planBadge(_ plan: String) -> String {
        plan.replacingOccurrences(of: "prolite", with: "pro_lite")
            .replacingOccurrences(of: "promax", with: "pro_max")
            .split(separator: "_")
            .map { UsageEngine.planBadge(String($0)) }
            .joined(separator: " ")
    }

    public func shifted(by offset: TimeInterval) -> CodexProvider {
        CodexProvider(
            appServer: appServer?.shifted(by: offset),
            sessionLog: sessionLog?.shifted(by: offset),
            usage: usage.map { $0.shifted(by: offset) }
        )
    }
}

extension CodexProvider {
    private enum CodingKeys: String, CodingKey {
        case codex, codexSessionLog
        /// Recorded app-server stdout lines, replayed into `appServer`.
        case codexAppServerMessages
        /// Recorded session-log lines, read into `sessionLog`.
        case codexSessionLogLines
        /// Recorded Codex rollout files, one array of lines per file, each
        /// read in order into `usage`.
        case codexRolloutFiles
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

    /// Reads its keys from a fixture's readings; each one missing or
    /// unreadable is no reading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appServer = (try? c.decodeIfPresent(CodexLimits.self, forKey: .codex))
            ?? (try? c.decodeIfPresent(RecordedAppServer.self, forKey: .codexAppServerMessages))?.limits
        sessionLog = (try? c.decodeIfPresent(CodexLimits.self, forKey: .codexSessionLog))
            ?? (try? c.decodeIfPresent([Lenient<CodexSessionLog.Line>].self, forKey: .codexSessionLogLines))
                .flatMap { CodexSessionLog.lastRecord(of: $0.compactMap(\.value))?.limits }
        var ledger = UsageLedger()
        let rolloutFiles = (try? c.decodeIfPresent([Lenient<[Lenient<CodexRollout.Line>]>].self, forKey: .codexRolloutFiles)) ?? []
        for (index, file) in rolloutFiles.compactMap(\.value).enumerated() {
            var parser = CodexRollout.Parser(path: "rollout-\(index).jsonl")
            ledger.add(file.compactMap { $0.value.flatMap { parser.receive($0) } })
        }
        usage = ledger.entries
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
