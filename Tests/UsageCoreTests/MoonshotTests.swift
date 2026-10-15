import Foundation
import Testing
import UsageCore

/// Moonshot's `GET /v1/users/me/balance` answers on its two platforms, from
/// synthetic fixtures built on the documented shape, through the engine to
/// what the popover shows.
@Suite("Moonshot")
struct MoonshotTests {
    func snapshot(_ name: String) throws -> UsageSnapshot {
        let fixture = try loadFixture(name)
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone, selection: fixture.selection)
    }

    /// One answer for `id`, received two minutes before the test clock.
    func snapshot(_ id: String = "moonshot", status: Int = 200, body: String) throws -> UsageSnapshot {
        let json = """
        { "now": "2026-10-10T14:40:00-07:00", "timeZone": "America/Los_Angeles", "readings": { "\(id)": [
          { "receivedAt": "2026-10-10T14:38:00-07:00", "status": \(status), "body": \(body) }
        ] } }
        """
        let fixture = try Fixture.decode(Data(json.utf8))
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
    }

    @Test("the international platform's available balance is a row in dollars, with voucher and cash as its detail")
    func balance() throws {
        let snapshot = try snapshot("moonshot-balance")
        #expect(snapshot.sections.map(\.name) == ["Moonshot"])
        let section = try #require(snapshot["moonshot"])
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(valueTexts(section) == ["Balance $49.59 · $46.59 voucher · $3.00 cash"])
        #expect(section.note == nil)
    }

    @Test("the China platform is its own provider, in yuan; negative cash is money owed")
    func china() throws {
        let snapshot = try snapshot("moonshot-cn-balance")
        #expect(snapshot.sections.map(\.name) == ["Moonshot China"])
        let section = try #require(snapshot["moonshot-cn"])
        #expect(valueTexts(section) == ["Balance ¥18.50 · ¥18.50 voucher · −¥2.75 cash"])
        #expect(section.note == nil)
    }

    @Test("success is judged from the HTTP status and data: a failing code with data still reads")
    func codeIgnored() throws {
        let section = try #require(try snapshot(body: """
            { "code": 1, "scode": "0x1", "status": false, "data": { "available_balance": 2.5, "voucher_balance": 0, "cash_balance": 2.5 } }
            """)["moonshot"])
        #expect(valueTexts(section) == ["Balance $2.50 · $0 voucher · $2.50 cash"])
        #expect(section.note == nil)
    }

    @Test("a successful code without data is no reading")
    func codeWithoutData() throws {
        let section = try #require(try snapshot(body: #"{ "code": 0, "scode": "0x0", "status": true }"#)["moonshot"])
        #expect(valueTexts(section) == ["Balance —"])
        #expect(section.note == "Couldn't read the answer from api.moonshot.ai")
    }

    @Test("a successful code on an error status is the error")
    func codeOnErrorStatus() throws {
        let section = try #require(try snapshot(status: 404, body: #"{ "code": 0, "status": true, "data": { "available_balance": 9 } }"#)["moonshot"])
        #expect(valueTexts(section) == ["Balance —"])
        #expect(section.note == "api.moonshot.ai answered HTTP 404")
    }

    @Test("after a rejected key the balance shows a dash and the note says so")
    func rejected() throws {
        let section = try #require(try snapshot("moonshot-rejected")["moonshot"])
        #expect(valueTexts(section) == ["Balance —"])
        #expect(section.note == "Key rejected")
    }

    @Test("a balance at or below zero says calls are refused")
    func low() throws {
        let section = try #require(try snapshot("moonshot-cn", body: """
            { "code": 0, "data": { "available_balance": 0, "voucher_balance": 0, "cash_balance": -4 } }
            """)["moonshot-cn"])
        #expect(valueTexts(section) == ["Balance ¥0 · ¥0 voucher · −¥4 cash"])
        #expect(section.note == "Balance too low")
    }

    @Test("missing and mistyped amounts degrade only their own parts; a missing available adds up voucher and cash")
    func tolerant() throws {
        func texts(_ data: String) throws -> [String] {
            valueTexts(try #require(try snapshot(body: #"{ "data": \#(data) }"#)["moonshot"]))
        }
        #expect(try texts(#"{ "available_balance": "12.5", "voucher_balance": "lots", "extra": true }"#) == ["Balance $12.50"])
        #expect(try texts(#"{ "voucher_balance": 4, "cash_balance": "1.5" }"#) == ["Balance $5.50 · $4 voucher · $1.50 cash"])
        #expect(try texts(#"{ "voucher_balance": 4, "cash_balance": -1 }"#) == ["Balance $4 · $4 voucher · −$1 cash"])
        #expect(try texts(#"{ "available_balance": null, "cash_balance": 2 }"#) == ["Balance —"])
    }

    @Test("each platform sends its key to its own host only")
    func hosts() {
        #expect(MoonshotAPI.hosts == ["api.moonshot.ai"])
        #expect(MoonshotChinaAPI.hosts == ["api.moonshot.cn"])
        #expect(DeepSeekAPI.hosts == ["api.deepseek.com"])
    }

    @Test("both platforms and DeepSeek are in the Providers menu as key providers, after OpenRouter")
    func catalog() {
        let keyed = BuiltInProviders.catalog.filter(\.usesKey).map(\.name)
        #expect(keyed == ["OpenRouter", "DeepSeek", "Moonshot", "Moonshot China"])
    }
}
