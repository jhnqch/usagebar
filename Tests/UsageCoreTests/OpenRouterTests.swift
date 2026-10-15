import Foundation
import Testing
import UsageCore

/// OpenRouter's `GET /api/v1/key` answers, from the synthetic fixtures built
/// on its documented shape, through the engine to what the popover shows.
@Suite("OpenRouter")
struct OpenRouterTests {
    func snapshot(_ name: String, at time: Date? = nil, alertMemory: AlertMemory = AlertMemory()) throws -> UsageSnapshot {
        let fixture = try loadFixture(name)
        let time = time ?? fixture.now
        return UsageEngine.snapshot(
            from: fixture.readings, now: time, timeZone: fixture.timeZone, alertMemory: alertMemory, selection: fixture.selection
        )
    }

    /// One answer's `data` object, received at the test clock's "now" minus
    /// two minutes.
    func snapshot(data: String, at time: Date = now) throws -> UsageSnapshot {
        let json = """
        { "now": "2026-10-10T14:40:00-07:00", "timeZone": "America/Los_Angeles", "readings": { "openrouter": [
          { "receivedAt": "2026-10-10T14:38:00-07:00", "status": 200, "body": { "data": \(data) } }
        ] } }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        return UsageEngine.snapshot(from: fixture.readings, now: time, timeZone: fixture.timeZone)
    }

    func texts(_ section: ProviderSection) -> [String] {
        section.rows.map { row in
            switch row {
            case let .meter(meter):
                "\(meter.label) \(meter.percentText)\(meter.resetText.map { " · \($0)" } ?? "")\(meter.usageText.map { " · \($0)" } ?? "")"
            case let .credit(credit): "\(credit.label) \(credit.valueText)\(credit.resetText.map { " · \($0)" } ?? "")"
            case let .value(value): "\(value.label) \(value.valueText)"
            }
        }
    }

    /// The key's monthly limit resets at midnight UTC on 1 Nov: 5 PM
    /// Saturday 31 Oct in Los Angeles.
    @Test("a key with a monthly limit shows its credit meter and spend for today, this week and this month")
    func limit() throws {
        let snapshot = try snapshot("openrouter-limit")
        #expect(snapshot.sections.map(\.name) == ["OpenRouter"])
        let section = try #require(snapshot["openrouter"])
        #expect(section.plan == nil)
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(texts(section) == [
            "Key limit $12.40 left of $20 · Resets Sat 5:00 PM",
            "Today $0.85",
            "This week $4.20",
            "This month $7.60",
        ])
        #expect(section.note == nil)
    }

    @Test("a key with no limit shows only its spend rows")
    func noLimit() throws {
        let section = try #require(try snapshot("openrouter-no-limit")["openrouter"])
        #expect(section.plan == nil)
        #expect(texts(section) == ["Today $1.92", "This week $14.35", "This month $38.06"])
    }

    /// Free models allow 50 requests a UTC day until $10 of credit is
    /// bought; the day ends at 5 PM in Los Angeles.
    @Test("a free-tier key shows the Free badge and its free-model requests left today")
    func freeTier() throws {
        let section = try #require(try snapshot("openrouter-free")["openrouter"])
        #expect(section.plan == "Free")
        #expect(texts(section) == [
            "Free requests 38 left of 50 · Resets in 2h 20m (5:00 PM)",
            "Today $0",
            "This week $0",
            "This month $0",
        ])
    }
}
