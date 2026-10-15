import Foundation

/// DeepSeek, read from `GET https://api.deepseek.com/user/balance` with the
/// user's API key (https://api-docs.deepseek.com/api/get-user-balance).
///
/// Its answer:
///
/// ```json
/// { "is_available": true,
///   "balance_infos": [{ "currency": "CNY", "total_balance": "110.00",
///                       "granted_balance": "10.00", "topped_up_balance": "100.00" }] }
/// ```
///
/// - Each of `balance_infos[]` is a balance row in its currency (documented
///   as CNY or USD; any other shows its code), with what was topped up and
///   what was granted as its detail. Amounts are documented as strings;
///   numbers are read too.
/// - `is_available` false (the balance can't pay for calls) is the note
///   "Balance too low".
public enum DeepSeekAPI: KeyAPI {
    public static let id = "deepseek"
    public static let name = "DeepSeek"
    public static let symbol = "◈"
    public static let systemImage = "fish"
    public static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    public static let keyHint: String? = "Create a key at platform.deepseek.com/api_keys"

    public struct Reading: Equatable, Sendable {
        /// Whether the balance can pay for API calls; nil when unreadable.
        public var isAvailable: Bool?
        public var balances: [Balance]
    }

    public struct Balance: Equatable, Sendable {
        /// "CNY", "USD", or whatever code DeepSeek sends.
        public var currency: String
        /// `total_balance`, or granted plus topped up without it.
        public var total: Double?
        public var granted: Double?
        public var toppedUp: Double?
    }

    public static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let balances = (root["balance_infos"] as? [Any] ?? []).compactMap(balance)
        let reading = Reading(isAvailable: root["is_available"] as? Bool, balances: balances)
        return reading.isAvailable == nil && balances.isEmpty ? nil : reading
    }

    /// One `balance_infos[]` entry; nil without a currency (an amount in an
    /// unknown currency is no reading, not yuan). Unreadable amounts leave
    /// their own parts nil, so the row shows "—".
    private static func balance(_ element: Any) -> Balance? {
        guard let entry = element as? [String: Any],
              let currency = (entry["currency"] as? String)?.trimmingCharacters(in: .whitespaces), !currency.isEmpty
        else { return nil }
        let granted = Amount.number(entry["granted_balance"])
        let toppedUp = Amount.number(entry["topped_up_balance"])
        let total = Amount.number(entry["total_balance"]) ?? granted.flatMap { granted in toppedUp.map { granted + $0 } }
        return Balance(currency: currency.uppercased(), total: total, granted: granted, toppedUp: toppedUp)
    }

    public static func report(_ reading: Reading?, clock: Clock) -> ProviderReport {
        let balances = reading?.balances ?? []
        var rows: [ProviderReport.Row] = []
        var ids: Set<String> = []
        for balance in balances where ids.insert(balance.currency).inserted {
            let unit = Amount.Unit.currency(balance.currency)
            let parts = [
                balance.toppedUp.map { "\(Amount($0, unit).text) topped up" },
                balance.granted.map { "\(Amount($0, unit).text) granted" },
            ].compactMap(\.self)
            rows.append(.value(ValueRow(
                id: "deepseek.balance.\(balance.currency)", label: "Balance", value: balance.total.map { Amount($0, unit) },
                detail: parts.isEmpty ? nil : parts.joined(separator: " · ")
            )))
        }
        if rows.isEmpty {
            rows.append(.value(ValueRow(id: "deepseek.balance", label: "Balance", value: nil)))
        }
        return ProviderReport(rows: rows, note: reading?.isAvailable == false ? "Balance too low" : nil)
    }

    /// Nothing in a balance answer is dated.
    public static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading { reading }
}
