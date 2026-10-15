import Foundation

/// A made-up key provider on `api.example.com` (a reserved domain), with
/// every kind of balance and spend row. It's the reference for writing a key
/// provider, and what the key fixtures and their snapshot evidence render.
/// It's in no catalog: the app never lists it, polls it or asks for its key.
/// Only a fixture with an `"example"` key shows it.
///
/// Its answer:
///
/// ```json
/// { "data": {
///     "plan": "prepaid",
///     "credit": { "remaining": "12.40", "limit": 20, "currency": "USD", "resets_at": "2026-11-01T07:00:00Z" },
///     "spend": { "today": 0.85, "this_month": "3.10", "currency": "USD" },
///     "balances": [{ "currency": "CNY", "amount": "48.20" }] } }
/// ```
///
/// Amounts come as numbers or as strings, as real APIs send them.
public enum ExampleKeyAPI: KeyAPI {
    public static let id = "example"
    public static let name = "Example API"
    public static let symbol = "◇"
    public static let systemImage = "key"
    public static let endpoint = URL(string: "https://api.example.com/v1/credits")!
    public static let keyHint: String? = "Create a key at example.com/keys"

    public struct Reading: Equatable, Sendable {
        public var plan: String?
        public var creditLeft: Amount?
        public var creditLimit: Amount?
        public var creditResetsAt: Date?
        public var spentToday: Amount?
        public var spentThisMonth: Amount?
        public var balances: [Amount]
    }

    public static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = root["data"] as? [String: Any] else { return nil }
        // An amount without a readable currency is no reading, not dollars.
        let credit = data["credit"] as? [String: Any] ?? [:]
        let creditCurrency = credit["currency"] as? String
        let spend = data["spend"] as? [String: Any] ?? [:]
        let spendCurrency = spend["currency"] as? String
        func amount(_ value: Any?, _ currency: String?) -> Amount? {
            guard let currency, let number = number(value) else { return nil }
            return Amount(number, .currency(currency))
        }
        // Each entry on its own: a malformed one drops only itself.
        let balances = (data["balances"] as? [Any] ?? []).compactMap { element -> Amount? in
            guard let entry = element as? [String: Any],
                  let currency = entry["currency"] as? String, let amount = number(entry["amount"]) else { return nil }
            return Amount(amount, .currency(currency))
        }
        let reading = Reading(
            plan: data["plan"] as? String,
            creditLeft: amount(credit["remaining"], creditCurrency),
            creditLimit: amount(credit["limit"], creditCurrency),
            creditResetsAt: (credit["resets_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) },
            spentToday: amount(spend["today"], spendCurrency),
            spentThisMonth: amount(spend["this_month"], spendCurrency),
            balances: balances
        )
        let empty = Reading(balances: [])
        return reading == empty ? nil : reading
    }

    public static func report(_ reading: Reading?, clock: Clock) -> ProviderReport {
        var rows: [ProviderReport.Row] = [
            .credit(CreditRow(id: "example.credit", label: "Credit", left: reading?.creditLeft, of: reading?.creditLimit,
                              resetsAt: reading?.creditResetsAt)),
            .value(ValueRow(id: "example.today", label: "Today", value: reading?.spentToday)),
            .value(ValueRow(id: "example.month", label: "This month", value: reading?.spentThisMonth)),
        ]
        for balance in reading?.balances ?? [] {
            let code = if case let .currency(code) = balance.unit { code } else { "" }
            rows.append(.value(ValueRow(id: "example.balance.\(code)", label: "Balance", value: balance)))
        }
        return ProviderReport(
            plan: reading?.plan.map { $0.split(separator: "_").joined(separator: " ") }.map(UsageEngine.planBadge),
            rows: rows
        )
    }

    public static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading {
        var copy = reading
        copy.creditResetsAt = reading.creditResetsAt.map { $0 + offset }
        return copy
    }

    /// A number, or a string holding one.
    private static func number(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string).flatMap { $0.isFinite ? $0 : nil } }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
}

extension ExampleKeyAPI.Reading {
    init(balances: [Amount]) {
        self.init(plan: nil, creditLeft: nil, creditLimit: nil, creditResetsAt: nil, spentToday: nil, spentThisMonth: nil, balances: balances)
    }
}
