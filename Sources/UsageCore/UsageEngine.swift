import Foundation

/// The usage engine: a pure function from readings and a clock to a snapshot.
public enum UsageEngine {
    public static func snapshot(from readings: Readings, now: Date, timeZone: TimeZone) -> UsageSnapshot {
        let clock = Clock(now: now, timeZone: timeZone)

        let claude = readings.claude
        let statusLine = readings.claudeStatusLine
        let claudeWindows = [
            Window(id: "claude.fiveHour", label: "5-hour session", reading: merged(statusLine?.fiveHour, claude?.fiveHour)),
            Window(id: "claude.sevenDay", label: "Weekly · all models", reading: merged(statusLine?.sevenDay, claude?.sevenDay)),
            // Fable comes only from the usage endpoint.
            Window(id: "claude.sevenDayFable", label: "Weekly · Fable", reading: claude?.sevenDayFable),
        ].map { $0.current(at: now) }

        let codex = fresher(readings.codex, readings.codexSessionLog)
        var codexWindows = (codex?.windows ?? [])
            .sorted { $0.windowMinutes < $1.windowMinutes }
            .map {
                Window(
                    id: "codex.\($0.windowMinutes)m",
                    label: label(forWindowMinutes: $0.windowMinutes),
                    reading: $0.reading
                ).current(at: now)
            }
        let codexHasFiveHour = codexWindows.contains { $0.id == "codex.300m" }
        if codexWindows.isEmpty {
            codexWindows = [Window(id: "codex.10080m", label: "Weekly", reading: nil)]
        }

        return UsageSnapshot(
            menuBar: MenuBarLabel(
                // Fable stays out: hitting it only blocks Fable.
                claude: labelPart(claudeWindows.prefix(2).compactMap(\.reading), clock: clock),
                codex: labelPart(codexWindows.compactMap(\.reading), clock: clock)
            ),
            claude: ServiceSection(
                plan: readings.claudePlan.map(planBadge),
                updatedText: [statusLine?.capturedAt, claude?.capturedAt].compactMap(\.self).max().map { clock.updatedText($0) },
                meters: claudeWindows.map { meter($0, clock: clock) },
                note: nil
            ),
            codex: ServiceSection(
                plan: codex?.plan.map(codexPlanBadge),
                updatedText: codex?.capturedAt.map { clock.updatedText($0) },
                meters: codexWindows.map { meter($0, clock: clock) },
                note: codex == nil || codexHasFiveHour || codex?.windows.isEmpty == true
                    ? nil : "No 5-hour limit on your plan"
            )
        )
    }

    /// Resets this close together belong to the same window. The two
    /// sources round them differently (the endpoint says 06:59:59.82 where the
    /// status line says 07:00:00), and a new 5-hour or weekly window resets
    /// hours or days after the one before.
    static let sameWindowTolerance: TimeInterval = 15 * 60

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
        return Meter(
            id: window.id,
            label: window.label,
            percentText: percentText(reading.usedPercent),
            fraction: min(max(reading.usedPercent, 0), 100) / 100,
            level: level,
            resetText: clock.resetText(reading.resetsAt, maxed: level == .maxed)
        )
    }

    private static func label(forWindowMinutes minutes: Int) -> String {
        switch minutes {
        case 300: "5-hour session"
        case 10080: "Weekly"
        case let m where m % 1440 == 0: "\(m / 1440)-day"
        case let m where m % 60 == 0: "\(m / 60)-hour"
        case let m: "\(m)-minute"
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

/// A named limit window and its reading, if any.
private struct Window {
    var id: String
    var label: String
    var reading: LimitReading?

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
