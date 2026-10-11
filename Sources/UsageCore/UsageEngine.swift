import Foundation

/// The usage engine: a pure function from readings and a clock to a snapshot.
public enum UsageEngine {
    public static func snapshot(from readings: Readings, now: Date, timeZone: TimeZone) -> UsageSnapshot {
        let clock = Clock(now: now, timeZone: timeZone)

        let claude = readings.claude
        let claudeWindows = [
            Window(id: "claude.fiveHour", label: "5-hour session", reading: claude?.fiveHour),
            Window(id: "claude.sevenDay", label: "Weekly · all models", reading: claude?.sevenDay),
            Window(id: "claude.sevenDayFable", label: "Weekly · Fable", reading: claude?.sevenDayFable),
        ].map { $0.current(at: now) }

        let codex = readings.codex
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
                plan: claude?.plan.map(planBadge),
                updatedText: claude.map { clock.updatedText($0.capturedAt) },
                meters: claudeWindows.map { meter($0, clock: clock) },
                note: nil
            ),
            codex: ServiceSection(
                plan: codex?.plan.map(planBadge),
                updatedText: codex.map { clock.updatedText($0.capturedAt) },
                meters: codexWindows.map { meter($0, clock: clock) },
                note: codex == nil || codexHasFiveHour || codex?.windows.isEmpty == true
                    ? nil : "No 5-hour limit on your plan"
            )
        )
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
