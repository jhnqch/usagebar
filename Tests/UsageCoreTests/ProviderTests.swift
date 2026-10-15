import Foundation
import Testing
import UsageCore

/// A provider the app doesn't ship: one daily limit window.
private struct DailyProvider: Provider {
    var id = "daily"
    var name = "Daily"
    var symbol = "◆"
    var systemImage = "circle"
    var plan: String? = "Team"
    var reading: LimitReading?

    func report(clock: Clock) -> ProviderReport {
        ProviderReport(
            plan: plan,
            updatedAt: reading.map { _ in clock.now - 60 },
            rows: [.window(LimitWindow(id: "daily.day", label: "Daily", minutes: 24 * 60, reading: reading, alertName: "Daily limit"))]
        )
    }

    func shifted(by offset: TimeInterval) -> DailyProvider {
        var copy = self
        copy.reading = reading.map { LimitReading(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt + offset) }
        return copy
    }
}

/// A provider with no limit windows, as a balance-only API key provider will be.
private struct WindowlessProvider: Provider {
    var id = "windowless"
    var name = "Windowless"
    var symbol = "○"
    var systemImage = "circle"

    func report(clock: Clock) -> ProviderReport {
        ProviderReport(note: "Nothing to show")
    }

    func shifted(by offset: TimeInterval) -> WindowlessProvider { self }
}

@Suite("Providers")
struct ProviderTests {
    private let daily = DailyProvider(reading: LimitReading(usedPercent: 95, resetsAt: date("2026-10-11T00:00:00-07:00")))

    private func snapshot(_ providers: [any Provider]) -> UsageSnapshot {
        UsageEngine.snapshot(from: Readings(providers), now: now, timeZone: losAngeles)
    }

    @Test("a third provider gets a section after the others, in display order")
    func thirdProviderSection() throws {
        let snapshot = snapshot([ClaudeProvider(), CodexProvider(), daily])
        #expect(snapshot.sections.map(\.name) == ["Claude", "Codex", "Daily"])
        let section = try #require(snapshot["daily"])
        #expect(section.symbol == "◆")
        #expect(section.plan == "Team")
        #expect(section.updatedText == "Updated 1 min ago")
        #expect(section.meters.map(\.label) == ["Daily"])
        #expect(section.meters.map(\.percentText) == ["95%"])
        #expect(section.meters.first?.level == .warning)
    }

    @Test("a third provider gets a menu bar part with its own symbol")
    func thirdProviderLabel() {
        let label = snapshot([ClaudeProvider(), CodexProvider(), daily]).menuBar
        #expect(label.text == "✳ — · ⌘ — · ◆ 95%")
        #expect(label["daily"] == LabelPart(text: "95%", level: .warning))
        #expect(label.accessibilityText == "Usage. Claude —. Codex —. Daily 95%.")
    }

    @Test("a third provider's windows alert like Claude's and Codex's")
    func thirdProviderAlerts() {
        let snapshot = snapshot([daily])
        #expect(snapshot.alerts.map(\.title) == ["Daily limit at 95%"])
        #expect(snapshot.alertMemory.cycles.map(\.window) == ["daily.day"])
    }

    @Test("the label follows the providers' order, and a provider without windows has no part")
    func labelOrder() {
        let label = snapshot([daily, WindowlessProvider(), ClaudeProvider()]).menuBar
        #expect(label.text == "◆ 95% · ✳ —")
        #expect(label["windowless"] == nil)
    }

    @Test("a provider without windows still gets its section")
    func windowlessSection() throws {
        let section = try #require(snapshot([WindowlessProvider()])["windowless"])
        #expect(section.meters.isEmpty)
        #expect(section.note == "Nothing to show")
    }

    @Test("readings compare equal only when every provider's readings do")
    func readingsEquality() {
        #expect(Readings([daily, ClaudeProvider()]) == Readings([daily, ClaudeProvider()]))
        #expect(Readings([daily]) != Readings([DailyProvider(reading: nil)]))
        #expect(Readings([daily, ClaudeProvider()]) != Readings([ClaudeProvider(), daily]))
    }

    @Test("changing one provider's readings leaves the others alone")
    func update() {
        var readings = Readings([ClaudeProvider(), daily])
        readings.update(DailyProvider.self) { $0.plan = "Solo" }
        #expect(readings == Readings([ClaudeProvider(), DailyProvider(plan: "Solo", reading: daily.reading)]))
        // A provider that isn't there isn't added.
        readings.update(CodexProvider.self) { $0.usage = [] }
        #expect(readings.providers.count == 2)
    }
}
