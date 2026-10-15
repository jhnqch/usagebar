import Foundation
import Testing
import UsageCore

/// The example key provider read from recorded answers: the fixtures the
/// snapshot evidence renders.
@Suite("Key provider fixtures")
struct KeyFixtureTests {
    func snapshot(_ name: String) throws -> UsageSnapshot {
        let fixture = try loadFixture(name)
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone, selection: fixture.selection)
    }

    func texts(_ section: ProviderSection) -> [String] {
        section.rows.map { row in
            switch row {
            case let .meter(meter): "\(meter.label) \(meter.percentText)"
            case let .credit(credit): "\(credit.label) \(credit.valueText)\(credit.resetText.map { " · \($0)" } ?? "")"
            case let .value(value): "\(value.label) \(value.valueText)"
            }
        }
    }

    @Test("a recorded answer shows credit, spend and balance rows")
    func balance() throws {
        let snapshot = try snapshot("key-balance")
        #expect(snapshot.sections.map(\.name) == ["Codex", "Example API"])
        let section = try #require(snapshot["example"])
        #expect(section.plan == "Prepaid")
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(texts(section) == [
            "Credit $12.40 left of $20 · Resets Sun 12:00 AM",
            "Today $0.85",
            "This month $3.10",
            "Balance ¥48.20",
        ])
        #expect(section.note == nil)
        #expect(snapshot.menuBar.text == "⌘ 13%")
    }

    @Test("after a rejected key the rows show dashes and the note says so")
    func rejected() throws {
        let section = try #require(try snapshot("key-rejected")["example"])
        #expect(texts(section) == ["Credit —", "Today —", "This month —"])
        #expect(section.note == "Key rejected")
        #expect(section.updatedText == nil)
    }

    @Test("missing and mistyped fields degrade only their own rows")
    func tolerant() throws {
        let json = """
        { "now": "2026-10-10T14:40:00-07:00", "timeZone": "America/Los_Angeles", "readings": { "example": [
          { "receivedAt": "2026-10-10T14:40:00-07:00", "status": 200,
            "body": { "data": { "credit": { "remaining": "lots", "limit": 20 }, "spend": { "today": null, "this_month": 3.1, "currency": "USD" },
                                "balances": [{ "currency": "CNY" }, null, 7, { "currency": "USD", "amount": "1.5" }] } } }
        ] } }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        let section = try #require(UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)["example"])
        #expect(texts(section) == ["Credit —", "Today —", "This month $3.10", "Balance $1.50"])
    }

    @Test("an amount whose currency is missing shows a dash rather than guessing dollars")
    func missingCurrency() throws {
        let json = """
        { "now": "2026-10-10T14:40:00-07:00", "timeZone": "America/Los_Angeles", "readings": { "example": [
          { "receivedAt": "2026-10-10T14:40:00-07:00", "status": 200,
            "body": { "data": { "credit": { "remaining": 5, "limit": 20 }, "spend": { "today": 1, "this_month": 2, "currency": 7 } } } }
        ] } }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        let section = try #require(UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)["example"])
        #expect(texts(section) == ["Credit —", "Today —", "This month —"])
    }

    @Test("fixtures without a key provider's answers show no section for it")
    func absent() throws {
        #expect(try snapshot("sample").sections.map(\.id) == ["claude", "codex"])
    }

    /// A day later the reset is 24 hours later in absolute time, which
    /// crosses the end of daylight saving on Sun 1 Nov: 11 PM, not midnight.
    @Test("a rebased fixture keeps the key provider's reading where it sat")
    func rebased() throws {
        let fixture = try loadFixture("key-balance")
        let later = fixture.now + 86400
        let section = try #require(UsageEngine.snapshot(from: fixture.readings(rebasedTo: later), now: later, timeZone: fixture.timeZone)["example"])
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(texts(section).first == "Credit $12.40 left of $20 · Resets Sun 11:00 PM")
    }

    @Test("no fixture holds anything that looks like a key or an Authorization header")
    func noKeysInFixtures() throws {
        let root = fixtureURL("")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in files where ["json", "jsonl"].contains(url.pathExtension) {
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for marker in [fakeKey, "Bearer ", "\"authorization\"", "\"Authorization\"", "sk-or-", "sk-ant-", "ghp_", "github_pat_"] {
                #expect(!text.contains(marker), "\(url.lastPathComponent) contains \(marker)")
            }
        }
        #expect(checked > 10)
    }
}
