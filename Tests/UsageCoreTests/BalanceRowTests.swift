import Foundation
import Testing
import UsageCore

/// A provider without limit windows that shows the rows it's given, as a
/// balance-only API key provider does.
private struct BalanceProvider: Provider {
    var id = "balance"
    var name = "Balance"
    var symbol = "¤"
    var systemImage = "creditcard"
    var rows: [ProviderReport.Row]

    init(rows: [ProviderReport.Row]) {
        self.rows = rows
    }

    init(from decoder: any Decoder) throws {
        rows = []
    }

    func report(clock: Clock) -> ProviderReport {
        ProviderReport(rows: rows)
    }

    func shifted(by offset: TimeInterval) -> BalanceProvider { self }
}

@Suite("Balance and spend rows")
struct BalanceRowTests {
    private func section(_ rows: ProviderReport.Row...) throws -> ProviderSection {
        try #require(UsageEngine.snapshot(from: Readings([BalanceProvider(rows: rows)]), now: now, timeZone: losAngeles)["balance"])
    }

    @Test("a credit row is a meter of what's used, reading what's left of the total")
    func credit() throws {
        let section = try section(.credit(CreditRow(
            id: "balance.credit", label: "Credit", left: Amount(12.40, .usd), of: Amount(20, .usd),
            resetsAt: date("2026-11-01T00:00:00-07:00")
        )))
        guard case let .credit(meter) = try #require(section.rows.first) else { Issue.record("not a credit meter"); return }
        #expect(meter.id == "balance.credit")
        #expect(meter.label == "Credit")
        #expect(meter.valueText == "$12.40 left of $20")
        #expect(abs(meter.fraction - 0.38) < 1e-9)
        #expect(meter.level == .normal)
        #expect(meter.resetText == "Resets Sun 12:00 AM")
    }

    @Test("a credit row warns from 90% used and is maxed with nothing left", arguments: [
        (1.99, Level.warning), (2.01, .normal), (0, .maxed), (-0.5, .maxed),
    ])
    func creditLevel(left: Double, level: Level) throws {
        let section = try section(.credit(CreditRow(id: "balance.credit", label: "Credit", left: Amount(left, .usd), of: Amount(20, .usd))))
        guard case let .credit(meter) = section.rows.first else { Issue.record("not a credit meter"); return }
        #expect(meter.level == level)
        #expect(meter.resetText == nil)
        #expect((0...1).contains(meter.fraction))
    }

    @Test("a credit row with no reading shows a dash")
    func creditMissing() throws {
        let section = try section(.credit(CreditRow(id: "balance.credit", label: "Credit", left: nil, of: Amount(20, .usd))))
        #expect(section.rows == [.credit(CreditMeter(id: "balance.credit", label: "Credit", valueText: "—", fraction: 0, level: .normal))])
    }

    @Test("a credit row without a total says what's left, with an empty bar")
    func creditWithoutTotal() throws {
        let section = try section(.credit(CreditRow(id: "balance.credit", label: "Credit", left: Amount(12.4, .usd), of: nil)))
        #expect(section.rows == [.credit(CreditMeter(id: "balance.credit", label: "Credit", valueText: "$12.40 left", fraction: 0, level: .normal))])
    }

    @Test("a value row is a label and an amount, or a dash without one")
    func values() throws {
        let section = try section(
            .value(ValueRow(id: "balance.cny", label: "Balance", value: Amount(48.2, .currency("CNY")))),
            .value(ValueRow(id: "balance.month", label: "This month", value: Amount(3.1, .usd))),
            .value(ValueRow(id: "balance.requests", label: "Premium requests", value: Amount(1234, .count("requests")))),
            .value(ValueRow(id: "balance.missing", label: "Today", value: nil))
        )
        #expect(section.rows == [
            .value(ValueLine(id: "balance.cny", label: "Balance", valueText: "¥48.20")),
            .value(ValueLine(id: "balance.month", label: "This month", valueText: "$3.10")),
            .value(ValueLine(id: "balance.requests", label: "Premium requests", valueText: "1,234 requests")),
            .value(ValueLine(id: "balance.missing", label: "Today", valueText: "—")),
        ])
        #expect(section.meters.isEmpty)
    }

    @Test("amounts: whole amounts drop the cents, other currencies use their code", arguments: [
        (Amount(20, .usd), "$20"),
        (Amount(0, .usd), "$0"),
        (Amount(0.004, .usd), "$0.00"),
        (Amount(1234.5, .usd), "$1,234.50"),
        (Amount(-3.25, .usd), "−$3.25"),
        (Amount(7, .currency("EUR")), "€7"),
        (Amount(7.5, .currency("CHF")), "7.50 CHF"),
        (Amount(1, .count("request")), "1 request"),
        (Amount(2.5, .count("credits")), "2.5 credits"),
    ])
    func amountText(amount: Amount, text: String) {
        #expect(amount.text == text)
    }

    @Test("balance rows keep their place among a provider's meters, and only windows alert or reach the menu bar")
    func mixedRows() throws {
        let window = LimitWindow(
            id: "balance.budget", label: "Budget", minutes: 7 * 24 * 60,
            reading: LimitReading(usedPercent: 95, resetsAt: date("2026-10-13T07:00:00-07:00")), alertName: "Balance budget"
        )
        let snapshot = UsageEngine.snapshot(
            from: Readings([BalanceProvider(rows: [
                .value(ValueRow(id: "balance.today", label: "Today", value: Amount(1, .usd))),
                .window(window),
                .credit(CreditRow(id: "balance.credit", label: "Credit", left: Amount(0, .usd), of: Amount(20, .usd))),
            ])]),
            now: now, timeZone: losAngeles
        )
        let section = try #require(snapshot["balance"])
        #expect(section.rows.map(\.id) == ["balance.today", "balance.budget", "balance.credit"])
        #expect(section.meters.map(\.id) == ["balance.budget"])
        #expect(snapshot.alerts.map(\.title) == ["Balance budget at 95%"])
        #expect(snapshot.menuBar.text == "¤ 95%")
    }
}
