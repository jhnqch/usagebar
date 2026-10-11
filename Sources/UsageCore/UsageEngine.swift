import Foundation

/// The usage engine: a pure function from readings and a clock to a snapshot.
public enum UsageEngine {
    /// The snapshot at `now`. `alertMemory` is what earlier evaluations
    /// alerted; the snapshot carries the alerts to post now and the memory to
    /// pass next time.
    public static func snapshot(
        from readings: Readings,
        now: Date,
        timeZone: TimeZone,
        alertMemory: AlertMemory = AlertMemory(),
        claudePrices: PriceTable = .claude,
        codexPrices: PriceTable = .codex
    ) -> UsageSnapshot {
        let clock = Clock(now: now, timeZone: timeZone)

        let claude = readings.claude
        let statusLine = readings.claudeStatusLine
        let fiveHour = merged(statusLine?.fiveHour, claude?.fiveHour)
        let weekly = merged(statusLine?.sevenDay, claude?.sevenDay)
        let claudeWindows = [
            Window(id: "claude.fiveHour", label: "5-hour session", minutes: fiveHourMinutes, reading: fiveHour,
                   alertNames: .init(near: "Claude 5-hour session", limit: "Claude 5-hour limit")),
            Window(id: "claude.sevenDay", label: "Weekly · all models", minutes: weekMinutes, reading: weekly,
                   alertNames: .init(limit: "Claude weekly limit")),
            // Fable comes only from the usage endpoint.
            Window(id: "claude.sevenDayFable", label: "Weekly · Fable", minutes: weekMinutes, reading: claude?.sevenDayFable,
                   alertNames: .init(limit: "Claude weekly Fable limit")),
        ].map { $0.current(at: now) }

        let codex = fresher(readings.codex, readings.codexSessionLog)
        var codexWindows = (codex?.windows ?? [])
            .sorted { $0.windowMinutes < $1.windowMinutes }
            .map {
                Window(
                    id: "codex.\($0.windowMinutes)m",
                    label: label(forWindowMinutes: $0.windowMinutes),
                    minutes: $0.windowMinutes,
                    reading: $0.reading,
                    alertNames: codexAlertNames(forWindowMinutes: $0.windowMinutes)
                ).current(at: now)
            }
        let codexHasFiveHour = codexWindows.contains { $0.id == "codex.300m" }
        // Windows are known by their length: on some plans the weekly one
        // comes in the primary slot.
        let codexWeekly = codex?.windows.first { $0.windowMinutes == weekMinutes }?.reading
        if codexWindows.isEmpty {
            codexWindows = [Window(id: "codex.10080m", label: "Weekly", minutes: weekMinutes, reading: nil, alertNames: .init(limit: "Codex weekly limit"))]
        }

        let claudeMeters = claudeWindows.map { meter($0, clock: clock) }
        let codexMeters = codexWindows.map { meter($0, clock: clock) }
        let alerts = LimitAlerts.evaluate(
            zip(claudeWindows + codexWindows, claudeMeters + codexMeters).map { window, meter in
                LimitAlerts.Window(id: window.id, names: window.alertNames, reading: window.reading, prediction: meter.prediction)
            },
            memory: alertMemory,
            clock: clock
        )

        return UsageSnapshot(
            menuBar: MenuBarLabel(
                // Fable stays out: hitting it only blocks Fable.
                claude: labelPart(claudeWindows.prefix(2).compactMap(\.reading), clock: clock),
                codex: labelPart(codexWindows.compactMap(\.reading), clock: clock)
            ),
            claude: ServiceSection(
                plan: readings.claudePlan.map(planBadge),
                updatedText: [statusLine?.capturedAt, claude?.capturedAt].compactMap(\.self).max().map { clock.updatedText($0) },
                meters: claudeMeters.withUsage(
                    UsageCost.session(readings.claudeUsage, window: fiveHour, now: now, prices: claudePrices),
                    on: "claude.fiveHour"
                ),
                note: nil,
                chart: UsageCost.weeklyChart(readings.claudeUsage, weekly: weekly, clock: clock, prices: claudePrices)
            ),
            codex: ServiceSection(
                plan: codex?.plan.map(codexPlanBadge),
                updatedText: codex?.capturedAt.map { clock.updatedText($0) },
                meters: codexMeters,
                note: codex == nil || codexHasFiveHour || codex?.windows.isEmpty == true
                    ? nil : "No 5-hour limit on your plan",
                chart: UsageCost.weeklyChart(readings.codexUsage, weekly: codexWeekly, clock: clock, prices: codexPrices)
            ),
            alerts: alerts.alerts,
            alertMemory: alerts.memory
        )
    }

    /// Resets this close together belong to the same window. The two
    /// sources round them differently (the endpoint says 06:59:59.82 where the
    /// status line says 07:00:00), and a new 5-hour or weekly window resets
    /// hours or days after the one before.
    static let sameWindowTolerance: TimeInterval = 15 * 60

    /// A weekly window's length, as Codex reports it.
    private static let weekMinutes = 7 * 24 * 60
    private static let fiveHourMinutes = 5 * 60

    /// One Claude window from the status line and the usage endpoint. Capture
    /// times can't decide it: an idle Claude Code session re-sends its last
    /// numbers with a fresh capture time. Within one window use only goes up,
    /// so the higher percent is the newer one (the status line's on a tie);
    /// across windows, the one that resets later is the newer window.
    private static func merged(_ statusLine: LimitReading?, _ endpoint: LimitReading?) -> LimitReading? {
        guard let statusLine, let endpoint else { return statusLine ?? endpoint }
        if abs(endpoint.resetsAt.timeIntervalSince(statusLine.resetsAt)) <= sameWindowTolerance {
            return endpoint.usedPercent > statusLine.usedPercent ? endpoint : statusLine
        }
        return endpoint.resetsAt > statusLine.resetsAt ? endpoint : statusLine
    }

    /// Whichever Codex reading was taken later; app-server on a tie.
    private static func fresher(_ appServer: CodexLimits?, _ sessionLog: CodexLimits?) -> CodexLimits? {
        guard let appServer, let sessionLog else { return appServer ?? sessionLog }
        return (sessionLog.capturedAt ?? .distantPast) > (appServer.capturedAt ?? .distantPast) ? sessionLog : appServer
    }

    /// The highest window's percent, or, while any window is maxed, the time
    /// until the last maxed window resets (when work can resume).
    private static func labelPart(_ readings: [LimitReading], clock: Clock) -> LabelPart {
        guard let highest = readings.map(\.usedPercent).max() else { return LabelPart(text: "—", level: .normal) }
        let maxedResets = readings.filter { Level(percent: $0.usedPercent) == .maxed }.map(\.resetsAt)
        if let resumeAt = maxedResets.max() {
            return LabelPart(text: clock.countdown(to: resumeAt), level: .maxed)
        }
        return LabelPart(text: percentText(highest), level: Level(percent: highest))
    }

    private static func meter(_ window: Window, clock: Clock) -> Meter {
        guard let reading = window.reading else {
            return Meter(id: window.id, label: window.label, percentText: "—", fraction: 0, level: .normal, resetText: nil)
        }
        let level = Level(percent: reading.usedPercent)
        let pace = Pace(reading: reading, minutes: window.minutes, clock: clock)
        return Meter(
            id: window.id,
            label: window.label,
            percentText: percentText(reading.usedPercent),
            fraction: min(max(reading.usedPercent, 0), 100) / 100,
            level: level,
            resetText: clock.resetText(reading.resetsAt),
            elapsed: pace?.elapsed,
            elapsedText: pace.map { "\(Int(($0.elapsed * 100).rounded()))% of window elapsed" },
            prediction: pace?.prediction
        )
    }

    private static func label(forWindowMinutes minutes: Int) -> String {
        switch minutes {
        case 300: "5-hour session"
        case weekMinutes: "Weekly"
        case let m where m % 1440 == 0: "\(m / 1440)-day"
        case let m where m % 60 == 0: "\(m / 60)-hour"
        case let m: "\(m)-minute"
        }
    }

    /// What a Codex window's alerts call it: "Codex weekly limit", "Codex 1-day limit".
    private static func codexAlertNames(forWindowMinutes minutes: Int) -> LimitAlerts.Names {
        switch minutes {
        case 300: .init(near: "Codex 5-hour session", limit: "Codex 5-hour limit")
        case weekMinutes: .init(limit: "Codex weekly limit")
        default: .init(limit: "Codex \(label(forWindowMinutes: minutes)) limit")
        }
    }

    private static func planBadge(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// Codex reports plan ids ("prolite", "edu_plus"); show them as names.
    private static func codexPlanBadge(_ plan: String) -> String {
        plan.replacingOccurrences(of: "prolite", with: "pro_lite")
            .replacingOccurrences(of: "promax", with: "pro_max")
            .split(separator: "_")
            .map { planBadge(String($0)) }
            .joined(separator: " ")
    }

    /// Whole percent, rounded down so the text never shows a level the value hasn't reached.
    static func percentText(_ percent: Double) -> String {
        "\(Int(min(max(percent, 0), 100).rounded(.down)))%"
    }
}

extension [Meter] {
    /// The meters with `usageText` set on the one with `id`.
    fileprivate func withUsage(_ text: String?, on id: String) -> [Meter] {
        map { meter in
            var meter = meter
            if meter.id == id { meter.usageText = text }
            return meter
        }
    }
}

/// A named limit window, its length and its reading, if any.
private struct Window {
    var id: String
    var label: String
    var minutes: Int
    var reading: LimitReading?
    var alertNames: LimitAlerts.Names

    func current(at now: Date) -> Window {
        var copy = self
        copy.reading = reading?.current(at: now)
        return copy
    }
}

extension LimitReading {
    /// The reading as of `now`: a window whose reset has passed reads 0% until
    /// a source reports the new window.
    func current(at now: Date) -> LimitReading {
        resetsAt <= now ? LimitReading(usedPercent: 0, resetsAt: resetsAt) : self
    }
}
