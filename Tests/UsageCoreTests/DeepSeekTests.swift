import Foundation
import Testing
import UsageCore

/// DeepSeek's `GET /user/balance` answers, from synthetic fixtures built on
/// its documented shape, through the engine to what the popover shows.
@Suite("DeepSeek")
struct DeepSeekTests {
    func snapshot(_ name: String) throws -> UsageSnapshot {
        let fixture = try loadFixture(name)
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone, selection: fixture.selection)
    }

    /// One 200 answer's body, received two minutes before the test clock.
    func snapshot(body: String) throws -> UsageSnapshot {
        let json = """
        { "now": "2026-10-10T14:40:00-07:00", "timeZone": "America/Los_Angeles", "readings": { "deepseek": [
          { "receivedAt": "2026-10-10T14:38:00-07:00", "status": 200, "body": \(body) }
        ] } }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
    }

    @Test("each currency's balance is a row, with topped-up and granted as its detail")
    func balance() throws {
        let snapshot = try snapshot("deepseek-balance")
        #expect(snapshot.sections.map(\.name) == ["DeepSeek"])
        let section = try #require(snapshot["deepseek"])
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(valueTexts(section) == [
            "Balance ¥110 · ¥100 topped up · ¥10 granted",
            "Balance $4.25 · $4.25 topped up · $0 granted",
        ])
        #expect(section.note == nil)
    }

    @Test("amounts sent as numbers read too, and a balance that can't pay for calls says so")
    func low() throws {
        let section = try #require(try snapshot("deepseek-low")["deepseek"])
        #expect(valueTexts(section) == ["Balance ¥0.12 · ¥0.12 topped up · ¥0 granted"])
        #expect(section.note == "Balance too low")
    }

    @Test("after a rejected key the balance shows a dash and the note says so")
    func rejected() throws {
        let section = try #require(try snapshot("deepseek-rejected")["deepseek"])
        #expect(valueTexts(section) == ["Balance —"])
        #expect(section.note == "Key rejected")
        #expect(section.updatedText == nil)
    }

    @Test("an unknown currency shows its code; malformed and currency-less entries drop out; a missing total adds up its parts; an unreadable one is a dash")
    func tolerant() throws {
        let section = try #require(try snapshot(body: """
            { "is_available": "yes", "something_new": 1, "balance_infos": [null, 7, { "total_balance": "5.00" },
              { "currency": "chf", "total_balance": "7.5", "granted_balance": null },
              { "currency": "CNY", "granted_balance": "2", "topped_up_balance": 3.5 },
              { "currency": "USD", "total_balance": "lots" }] }
            """)["deepseek"])
        #expect(valueTexts(section) == [
            "Balance 7.50 CHF",
            "Balance ¥5.50 · ¥3.50 topped up · ¥2 granted",
            "Balance —",
        ])
        #expect(section.note == nil)
    }

    @Test("an answer with nothing readable shows a dash and says it couldn't be read")
    func unreadable() throws {
        let section = try #require(try snapshot(body: #"{ "balances": [{ "currency": "CNY", "amount": "1" }] }"#)["deepseek"])
        #expect(valueTexts(section) == ["Balance —"])
        #expect(section.note == "Couldn't read the answer from api.deepseek.com")
    }
}

/// Each row as "label value · detail".
func valueTexts(_ section: ProviderSection) -> [String] {
    section.rows.map { row in
        switch row {
        case let .meter(meter): "\(meter.label) \(meter.percentText)"
        case let .credit(credit): "\(credit.label) \(credit.valueText)"
        case let .value(value): "\(value.label) \(value.valueText)\(value.detailText.map { " · \($0)" } ?? "")"
        }
    }
}
