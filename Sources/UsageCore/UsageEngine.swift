import Foundation

/// The usage engine: a pure function from readings and a clock to a snapshot.
public enum UsageEngine {
    /// The snapshot at `now`. `alertMemory` is what earlier evaluations
    /// alerted; the snapshot carries the alerts to post now and the memory to
    /// pass next time.
    ///
    /// `selection` picks the providers shown and those with a menu bar part;
    /// nil shows every provider with a part. A provider that's off neither
    /// shows nor alerts, and what it alerted before is kept as it was.
    public static func snapshot(
        from readings: Readings,
        now: Date,
        timeZone: TimeZone,
        alertMemory: AlertMemory = AlertMemory(),
        selection: ProviderSelection? = nil
    ) -> UsageSnapshot {
        let clock = Clock(now: now, timeZone: timeZone)
        var sections: [ProviderSection] = []
        var parts: [MenuBarLabel.Part] = []
        var alertWindows: [LimitAlerts.Window] = []

        let shown = readings.providers.filter { selection?.enabled.contains($0.id) ?? true }
        for provider in shown {
            let report = provider.report(clock: clock)
            let windows = report.windows.map { $0.current(at: now) }
            let meters = windows.map { meter($0, clock: clock) }
            alertWindows += zip(windows, meters).map { window, meter in
                LimitAlerts.Window(
                    id: window.id, names: .init(near: window.nearAlertName, limit: window.alertName),
                    reading: window.reading, prediction: meter.prediction
                )
            }
            let labelWindows = windows.filter(\.inMenuBar)
            if !labelWindows.isEmpty, selection?.menuBar.contains(provider.id) ?? true {
                parts.append(MenuBarLabel.Part(
                    id: provider.id, name: provider.name, symbol: provider.symbol,
                    value: labelPart(labelWindows.compactMap(\.reading), clock: clock)
                ))
            }
            sections.append(ProviderSection(
                id: provider.id,
                name: provider.name,
                symbol: provider.symbol,
                systemImage: provider.systemImage,
                plan: report.plan,
                updatedText: report.updatedAt.map { clock.updatedText($0) },
                rows: meters.map { .meter($0) },
                note: report.note,
                chart: report.chart
            ))
        }

        // A provider that's off sits out: its cycles are kept, so turning it
        // back on repeats no alert, and a reset that passes while it's off
        // is marked announced without an alert.
        let hidden = Set(readings.providers.map(\.id)).subtracting(shown.map(\.id))
        let (asleep, awake) = alertMemory.partitioned { cycle in hidden.contains { cycle.window.hasPrefix("\($0).") } }
        var alerts = LimitAlerts.evaluate(alertWindows, memory: awake, clock: clock)
        alerts.memory = alerts.memory.adding(asleep.map { $0.silencingReset(at: now) })
        return UsageSnapshot(
            menuBar: MenuBarLabel(parts: parts),
            sections: sections,
            alerts: alerts.alerts,
            alertMemory: alerts.memory,
            emptyText: sections.isEmpty ? emptyText : nil
        )
    }

    /// What the popover says with no provider on.
    static let emptyText = """
        No providers are on. UsageBar shows Claude once Claude Code is set up (~/.claude) \
        and Codex once Codex or the ChatGPT app is installed (~/.codex). \
        Turn one on under Providers.
        """

    /// Resets this close together belong to the same window. Two sources
    /// round them differently (Claude's endpoint says 06:59:59.82 where its
    /// status line says 07:00:00), and a new 5-hour or weekly window resets
    /// hours or days after the one before.
    static let sameWindowTolerance: TimeInterval = 15 * 60

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

    private static func meter(_ window: LimitWindow, clock: Clock) -> Meter {
        guard let reading = window.reading else {
            return Meter(id: window.id, label: window.label, percentText: "—", fraction: 0, level: .normal, resetText: nil,
                         usageText: window.usageText)
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
            usageText: window.usageText,
            elapsed: pace?.elapsed,
            elapsedText: pace.map { "\(Int(($0.elapsed * 100).rounded()))% of window elapsed" },
            prediction: pace?.prediction
        )
    }

    /// A plan id as a badge: "pro" reads "Pro".
    static func planBadge(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// Whole percent, rounded down so the text never shows a level the value hasn't reached.
    static func percentText(_ percent: Double) -> String {
        "\(Int(min(max(percent, 0), 100).rounded(.down)))%"
    }
}

extension LimitWindow {
    /// The window as of `now`: once its reset has passed it reads 0%.
    func current(at now: Date) -> LimitWindow {
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
