import Foundation

/// Claude (Claude Code and the Claude apps): 5-hour, weekly and weekly Fable
/// limits from the status line and the usage endpoint, and Claude Code's
/// cost from its transcripts.
public struct ClaudeProvider: Provider {
    public var id: String { "claude" }
    public var name: String { "Claude" }
    public var symbol: String { "✳" }
    public var systemImage: String { "asterisk" }

    /// Claude's plan name for the badge, e.g. "Max". Neither Claude
    /// source reports it, so the app bundles it.
    public var plan: String?
    /// Claude limits from the usage endpoint: the only source for Fable, and
    /// server-side, so they include the desktop app and claude.ai.
    public var endpoint: ClaudeLimits?
    /// Claude's 5-hour and weekly limits from the status line file, the
    /// live source while Claude Code is in use.
    public var statusLine: ClaudeLimits?
    /// Claude Code's replies from its transcripts, one per message,
    /// de-duplicated: the cost chart and the session's cost.
    public var usage: [UsageEntry]

    public init(plan: String? = nil, endpoint: ClaudeLimits? = nil, statusLine: ClaudeLimits? = nil, usage: [UsageEntry] = []) {
        self.plan = plan
        self.endpoint = endpoint
        self.statusLine = statusLine
        self.usage = usage
    }

    private static let weekMinutes = 7 * 24 * 60
    private static let fiveHourMinutes = 5 * 60

    public func report(clock: Clock) -> ProviderReport {
        let fiveHour = Self.merged(statusLine?.fiveHour, endpoint?.fiveHour)
        let weekly = Self.merged(statusLine?.sevenDay, endpoint?.sevenDay)
        return ProviderReport(
            plan: plan.map(UsageEngine.planBadge),
            updatedAt: [statusLine?.capturedAt, endpoint?.capturedAt].compactMap(\.self).max(),
            rows: [
                .window(LimitWindow(
                    id: "claude.fiveHour", label: "5-hour session", minutes: Self.fiveHourMinutes, reading: fiveHour,
                    alertName: "Claude 5-hour limit", nearAlertName: "Claude 5-hour session",
                    usageText: UsageCost.session(usage, window: fiveHour, now: clock.now, prices: .claude)
                )),
                .window(LimitWindow(
                    id: "claude.sevenDay", label: "Weekly · all models", minutes: Self.weekMinutes, reading: weekly,
                    alertName: "Claude weekly limit"
                )),
                // Fable comes only from the usage endpoint, and stays out of
                // the menu bar: hitting it only blocks Fable.
                .window(LimitWindow(
                    id: "claude.sevenDayFable", label: "Weekly · Fable", minutes: Self.weekMinutes, reading: endpoint?.sevenDayFable,
                    alertName: "Claude weekly Fable limit", inMenuBar: false
                )),
            ],
            chart: UsageCost.weeklyChart(usage, weekly: weekly, clock: clock, prices: .claude)
        )
    }

    /// One Claude window from the status line and the usage endpoint. Capture
    /// times can't decide it: an idle Claude Code session re-sends its last
    /// numbers with a fresh capture time. Within one window use only goes up,
    /// so the higher percent is the newer one (the status line's on a tie);
    /// across windows, the one that resets later is the newer window.
    private static func merged(_ statusLine: LimitReading?, _ endpoint: LimitReading?) -> LimitReading? {
        guard let statusLine, let endpoint else { return statusLine ?? endpoint }
        if abs(endpoint.resetsAt.timeIntervalSince(statusLine.resetsAt)) <= UsageEngine.sameWindowTolerance {
            return endpoint.usedPercent > statusLine.usedPercent ? endpoint : statusLine
        }
        return endpoint.resetsAt > statusLine.resetsAt ? endpoint : statusLine
    }

    public func shifted(by offset: TimeInterval) -> ClaudeProvider {
        ClaudeProvider(
            plan: plan,
            endpoint: endpoint?.shifted(by: offset),
            statusLine: statusLine?.shifted(by: offset),
            usage: usage.map { $0.shifted(by: offset) }
        )
    }
}

extension ClaudeProvider {
    private enum CodingKeys: String, CodingKey {
        case claudePlan, claude, claudeStatusLine
        /// Recorded usage-endpoint answers, replayed into `endpoint`.
        case claudeUsagePolls
        /// Recorded status line JSON, run through the status line command
        /// into `statusLine`.
        case claudeStatusLineInputs
        /// Recorded Claude Code transcript lines, read and de-duplicated
        /// into `usage`.
        case claudeTranscriptLines
    }

    /// Reads its keys from a fixture's readings; each one missing or
    /// unreadable is no reading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try? c.decodeIfPresent(String.self, forKey: .claudePlan)
        endpoint = (try? c.decodeIfPresent(ClaudeLimits.self, forKey: .claude))
            ?? (try? c.decodeIfPresent([Lenient<RecordedPoll>].self, forKey: .claudeUsagePolls))
                .flatMap { ClaudeUsagePolling.replay($0.compactMap(\.value)) }
        statusLine = (try? c.decodeIfPresent(ClaudeLimits.self, forKey: .claudeStatusLine))
            ?? (try? c.decodeIfPresent([ClaudeStatusLine.RecordedInput].self, forKey: .claudeStatusLineInputs))
                .flatMap(ClaudeStatusLine.replay)
        var ledger = UsageLedger()
        ledger.add(((try? c.decodeIfPresent([Lenient<ClaudeTranscript.Line>].self, forKey: .claudeTranscriptLines)) ?? [])
            .compactMap { $0.value?.entry })
        usage = ledger.entries
    }
}

/// Claude's limit windows: 5-hour session, weekly (all models), weekly Fable.
public struct ClaudeLimits: Decodable, Equatable, Sendable {
    /// When the source took the reading; nil when it isn't readable.
    public var capturedAt: Date?
    public var fiveHour: LimitReading?
    public var sevenDay: LimitReading?
    public var sevenDayFable: LimitReading?

    public init(
        capturedAt: Date?,
        fiveHour: LimitReading? = nil,
        sevenDay: LimitReading? = nil,
        sevenDayFable: LimitReading? = nil
    ) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayFable = sevenDayFable
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, fiveHour, sevenDay, sevenDayFable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
        fiveHour = try? c.decodeIfPresent(LimitReading.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(LimitReading.self, forKey: .sevenDay)
        sevenDayFable = try? c.decodeIfPresent(LimitReading.self, forKey: .sevenDayFable)
    }

    func shifted(by offset: TimeInterval) -> ClaudeLimits {
        ClaudeLimits(
            capturedAt: capturedAt.map { $0 + offset },
            fiveHour: fiveHour?.shifted(by: offset),
            sevenDay: sevenDay?.shifted(by: offset),
            sevenDayFable: sevenDayFable?.shifted(by: offset)
        )
    }
}
