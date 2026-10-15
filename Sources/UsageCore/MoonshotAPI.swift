import Foundation

/// Moonshot's Kimi API balance, read from `GET /v1/users/me/balance` with
/// the user's API key (https://platform.kimi.ai/docs/api/balance).
///
/// Its answer:
///
/// ```json
/// { "code": 0,
///   "data": { "available_balance": 49.58894, "voucher_balance": 46.58893, "cash_balance": 3.00001 },
///   "scode": "0x0", "status": true }
/// ```
///
/// - `available_balance` (voucher plus cash) is a balance row, with the
///   voucher and cash balances as its detail. Cash can be negative (owed).
///   Amounts are documented as numbers; strings are read too.
/// - At or below zero, inference calls are refused: the note
///   "Balance too low".
/// - Success is judged from the HTTP status and `data`, never `code`,
///   `scode` or `status`: the docs contradict themselves on them.
///
/// Moonshot runs two platforms whose keys don't work on each other's host
/// and whose balances are in different currencies, so each is its own
/// provider with its own key and one pinned host: `MoonshotAPI`
/// (international, api.moonshot.ai, dollars) and `MoonshotChinaAPI`
/// (China, api.moonshot.cn, yuan).
public protocol MoonshotPlatformAPI: KeyAPI where Reading == MoonshotBalance {
    /// The currency the platform's amounts are in.
    static var currency: String { get }
}

/// What a Moonshot balance answer says.
public struct MoonshotBalance: Equatable, Sendable {
    /// `available_balance`, or without it voucher plus any positive cash.
    public var available: Double?
    public var voucher: Double?
    public var cash: Double?
}

extension MoonshotPlatformAPI {
    public static func reading(fromResponse body: Data, receivedAt: Date) -> MoonshotBalance? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = root["data"] as? [String: Any] else { return nil }
        let voucher = Amount.number(data["voucher_balance"])
        let cash = Amount.number(data["cash_balance"])
        let available = Amount.number(data["available_balance"])
            ?? voucher.flatMap { voucher in cash.map { voucher + max($0, 0) } }
        let reading = MoonshotBalance(available: available, voucher: voucher, cash: cash)
        return reading == MoonshotBalance() ? nil : reading
    }

    public static func report(_ reading: MoonshotBalance?, clock: Clock) -> ProviderReport {
        let unit = Amount.Unit.currency(currency)
        let parts = [
            reading?.voucher.map { "\(Amount($0, unit).text) voucher" },
            reading?.cash.map { "\(Amount($0, unit).text) cash" },
        ].compactMap(\.self)
        let row = ValueRow(id: "\(id).balance", label: "Balance", value: reading?.available.map { Amount($0, unit) },
                           detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
        let low = reading?.available.map { $0 <= 0 } == true
        return ProviderReport(rows: [.value(row)], note: low ? "Balance too low" : nil)
    }

    /// Nothing in a balance answer is dated.
    public static func shift(_ reading: MoonshotBalance, by offset: TimeInterval) -> MoonshotBalance { reading }
}

/// Moonshot's international platform (platform.kimi.ai): amounts in dollars.
public enum MoonshotAPI: MoonshotPlatformAPI {
    public static let id = "moonshot"
    public static let name = "Moonshot"
    public static let symbol = "☾"
    public static let systemImage = "moon"
    public static let endpoint = URL(string: "https://api.moonshot.ai/v1/users/me/balance")!
    public static let keyHint: String? = "Create a key at platform.kimi.ai/console/api-keys"
    public static let currency = "USD"
}

/// Moonshot's China platform (platform.kimi.com, formerly
/// platform.moonshot.cn): amounts in yuan.
public enum MoonshotChinaAPI: MoonshotPlatformAPI {
    public static let id = "moonshot-cn"
    public static let name = "Moonshot China"
    public static let symbol = "☾"
    public static let systemImage = "moon"
    public static let endpoint = URL(string: "https://api.moonshot.cn/v1/users/me/balance")!
    public static let keyHint: String? = "Create a key at platform.kimi.com/console/api-keys"
    public static let currency = "CNY"
}
