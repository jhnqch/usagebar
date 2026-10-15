import Foundation

/// OpenRouter, read from `GET https://openrouter.ai/api/v1/key` with the
/// user's API key (https://openrouter.ai/docs/api-reference/limits).
///
/// Its answer, abridged:
///
/// ```json
/// { "data": {
///     "limit": 20, "limit_remaining": 12.4, "limit_reset": "monthly",
///     "usage_daily": 0.85, "usage_weekly": 4.2, "usage_monthly": 7.6,
///     "is_free_tier": false,
///     "budgets": [{ "scope": "api_key", "guardrail_id": "…", "limit_usd": 10, "spend_usd": 9.2,
///                   "remaining_usd": 0.8, "reset_interval": "daily", "resets_at": "2026-10-11T00:00:00Z" }] } }
/// ```
///
/// - `limit` (null: unlimited) and `limit_remaining` are the key's own
///   credit cap: a credit meter. Credits are dollars on OpenRouter.
///   `limit_reset` is "daily", "weekly", "monthly" or null (never); resets
///   fall at midnight UTC, weeks start on Monday.
/// - `usage_daily/weekly/monthly` are what the key spent this UTC day,
///   week and month: value rows.
/// - Each of `budgets[]` (guardrails and workspace budgets, in dollars) is
///   a limit window, so it gets pace and the 90% and reset alerts. The
///   `key_limit` budget repeats the key's limit, already shown as the
///   credit meter, so it's left out. A budget that never resets has no
///   window to pace or alert on, so it's a credit meter instead.
/// - `is_free_tier` shows the plan badge "Free".
public enum OpenRouterAPI: KeyAPI {
    public static let id = "openrouter"
    public static let name = "OpenRouter"
    public static let symbol = "⊛"
    public static let systemImage = "point.3.connected.trianglepath.dotted"
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/key")!
    public static let keyHint: String? = "Create a key at openrouter.ai/settings/keys"

    public struct Reading: Equatable, Sendable {
        /// When the answer came: the UTC day, week and month its spend
        /// belongs to.
        public var receivedAt: Date
        public var isFreeTier: Bool?
        public var keyLimit: KeyLimit
        public var spentToday: Double?
        public var spentThisWeek: Double?
        public var spentThisMonth: Double?
        public var budgets: [Budget]
    }

    /// The key's own credit cap.
    public enum KeyLimit: Equatable, Sendable {
        /// `limit` is null: no cap, no row.
        case unlimited
        /// `limit` is missing or unreadable: the row shows "—".
        case unknown
        /// `left` is nil when `limit_remaining` is unreadable. `resetsAt` is
        /// the next midnight UTC that `limit_reset` names after the answer
        /// came, nil when it never resets.
        case limited(left: Double?, limit: Double, resetsAt: Date?)
    }

    public struct Budget: Equatable, Sendable {
        /// "api_key", "workspace", …; nil when unreadable.
        public var scope: String?
        /// `budget_id` or `guardrail_id`, when given: keeps the window's id
        /// stable if budgets are reordered.
        public var budgetID: String?
        /// "daily", "weekly", "monthly", or nil (never resets, or unknown).
        public var interval: String?
        public var limit: Double?
        public var spent: Double?
        public var resetsAt: Date?
    }

    public static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = root["data"] as? [String: Any] else { return nil }

        let keyLimit: KeyLimit
        switch data["limit"] {
        case is NSNull: keyLimit = .unlimited
        case let value:
            if let limit = number(value) {
                let resetsAt = (data["limit_reset"] as? String).flatMap { nextReset(after: receivedAt, interval: $0) }
                keyLimit = .limited(left: number(data["limit_remaining"]), limit: limit, resetsAt: resetsAt)
            } else {
                keyLimit = .unknown
            }
        }

        let reading = Reading(
            receivedAt: receivedAt,
            isFreeTier: data["is_free_tier"] as? Bool,
            keyLimit: keyLimit,
            spentToday: number(data["usage_daily"]),
            spentThisWeek: number(data["usage_weekly"]),
            spentThisMonth: number(data["usage_monthly"]),
            budgets: []
        )
        let empty = Reading(receivedAt: receivedAt, isFreeTier: nil, keyLimit: .unknown, spentToday: nil, spentThisWeek: nil,
                            spentThisMonth: nil, budgets: [])
        return reading == empty ? nil : reading
    }

    public static func report(_ reading: Reading?, clock: Clock) -> ProviderReport {
        var rows: [ProviderReport.Row] = []
        switch reading?.keyLimit {
        case nil, .unlimited:
            break
        case .unknown:
            rows.append(.credit(CreditRow(id: "openrouter.limit", label: "Key limit", left: nil, of: nil)))
        case let .limited(left, limit, resetsAt):
            rows.append(.credit(CreditRow(id: "openrouter.limit", label: "Key limit", left: left.map(dollars), of: dollars(limit),
                                          resetsAt: resetsAt)))
        }
        rows += [
            .value(ValueRow(id: "openrouter.today", label: "Today", value: reading?.spentToday.map(dollars))),
            .value(ValueRow(id: "openrouter.week", label: "This week", value: reading?.spentThisWeek.map(dollars))),
            .value(ValueRow(id: "openrouter.month", label: "This month", value: reading?.spentThisMonth.map(dollars))),
        ]
        return ProviderReport(plan: reading?.isFreeTier == true ? "Free" : nil, rows: rows)
    }

    public static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading {
        var copy = reading
        copy.receivedAt = reading.receivedAt + offset
        if case let .limited(left, limit, resetsAt) = reading.keyLimit {
            copy.keyLimit = .limited(left: left, limit: limit, resetsAt: resetsAt.map { $0 + offset })
        }
        copy.budgets = reading.budgets.map { budget in
            var moved = budget
            moved.resetsAt = budget.resetsAt.map { $0 + offset }
            return moved
        }
        return copy
    }

    private static func dollars(_ value: Double) -> Amount {
        Amount(value, .usd)
    }

    /// The UTC calendar OpenRouter's days, weeks (from Monday) and months
    /// follow.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The first midnight UTC after `date` that starts a new day, week
    /// (Monday) or month; nil for any other interval.
    static func nextReset(after date: Date, interval: String) -> Date? {
        let components: DateComponents
        switch interval.lowercased() {
        case "daily": components = DateComponents(hour: 0, minute: 0, second: 0)
        case "weekly": components = DateComponents(hour: 0, minute: 0, second: 0, weekday: 2)
        case "monthly": components = DateComponents(day: 1, hour: 0, minute: 0, second: 0)
        default: return nil
        }
        return utc.nextDate(after: date, matching: components, matchingPolicy: .strict)
    }

    /// A number, or a string holding one.
    private static func number(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string).flatMap { $0.isFinite ? $0 : nil } }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
}
