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
/// - `is_free_tier` shows the plan badge "Free" and, from
///   `free_model_daily_requests`, the free-model requests left this UTC
///   day (with no credit bought, that's all the key can use).
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
        /// Free-model requests left today and allowed a day.
        public var freeRequestsLeft: Double?
        public var freeRequestsLimit: Double?
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
        /// `spend_usd`, or `limit_usd - remaining_usd` without it.
        public var spent: Double?
        /// `resets_at`, or without it the next midnight UTC `interval`
        /// names; nil when it never resets.
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

        let freeRequests = data["free_model_daily_requests"] as? [String: Any] ?? [:]
        let reading = Reading(
            receivedAt: receivedAt,
            isFreeTier: data["is_free_tier"] as? Bool,
            keyLimit: keyLimit,
            spentToday: number(data["usage_daily"]),
            spentThisWeek: number(data["usage_weekly"]),
            spentThisMonth: number(data["usage_monthly"]),
            budgets: (data["budgets"] as? [Any] ?? []).compactMap { budget($0, receivedAt: receivedAt) },
            freeRequestsLeft: number(freeRequests["remaining"]),
            freeRequestsLimit: number(freeRequests["limit"])
        )
        let empty = Reading(receivedAt: receivedAt, isFreeTier: nil, keyLimit: .unknown, spentToday: nil, spentThisWeek: nil,
                            spentThisMonth: nil, budgets: [], freeRequestsLeft: nil, freeRequestsLimit: nil)
        return reading == empty ? nil : reading
    }

    /// One `budgets[]` entry; nil when it isn't an object or is the
    /// `key_limit` budget, which the key limit row already shows.
    private static func budget(_ element: Any, receivedAt: Date) -> Budget? {
        guard let entry = element as? [String: Any] else { return nil }
        let scope = entry["scope"] as? String
        guard scope != "key_limit" else { return nil }
        let interval = (entry["reset_interval"] as? String)?.lowercased()
        let limit = number(entry["limit_usd"])
        let spent = number(entry["spend_usd"]) ?? number(entry["remaining_usd"]).flatMap { remaining in limit.map { $0 - remaining } }
        let resetsAt = (entry["resets_at"] as? String).flatMap(date) ?? interval.flatMap { nextReset(after: receivedAt, interval: $0) }
        let budgetID = [entry["budget_id"], entry["guardrail_id"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
        return Budget(scope: scope, budgetID: budgetID, interval: interval, limit: limit, spent: spent, resetsAt: resetsAt)
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
        var ids: Set<String> = []
        for budget in reading?.budgets ?? [] {
            rows.append(row(budget, ids: &ids))
        }
        if let reading, reading.isFreeTier == true {
            let requests = Amount.Unit.count("")
            rows.append(.credit(CreditRow(
                id: "openrouter.freeRequests", label: "Free requests",
                left: reading.freeRequestsLeft.map { Amount($0, requests) }, of: reading.freeRequestsLimit.map { Amount($0, requests) },
                resetsAt: nextReset(after: reading.receivedAt, interval: "daily")
            )))
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

    /// A budget that resets as a limit window, so it gets pace and alerts;
    /// one that never resets as a credit meter.
    private static func row(_ budget: Budget, ids: inout Set<String>) -> ProviderReport.Row {
        let noun = switch budget.scope {
        case "api_key", "workspace_default_key": "key budget"
        case "member", "workspace_default_member": "member budget"
        case "workspace": "workspace budget"
        default: "budget"
        }
        let period = switch budget.interval {
        case "daily": "daily "
        case "weekly": "weekly "
        case "monthly": "monthly "
        default: ""
        }
        let name = period + noun
        let label = name.prefix(1).uppercased() + name.dropFirst()

        // Known by its id when OpenRouter gives one, so alert memory follows
        // it if budgets are reordered; a repeat gets a suffix.
        let base = "openrouter.budget.\(budget.budgetID ?? "\(budget.scope ?? "unknown").\(budget.interval ?? "none")")"
        var id = base
        var suffix = 2
        while !ids.insert(id).inserted {
            id = "\(base).\(suffix)"
            suffix += 1
        }

        guard let resetsAt = budget.resetsAt else {
            return .credit(CreditRow(id: id, label: label, left: budget.limit.flatMap { limit in budget.spent.map { dollars(limit - $0) } },
                                     of: budget.limit.map(dollars)))
        }
        let reading: LimitReading? = budget.limit.flatMap { limit in
            budget.spent.map { spent in
                LimitReading(usedPercent: limit > 0 ? spent / limit * 100 : 100, resetsAt: resetsAt)
            }
        }
        let usage = budget.limit.flatMap { limit in budget.spent.map { "\(dollars($0).text) of \(dollars(limit).text) spent" } }
        return .window(LimitWindow(
            id: id, label: label, minutes: windowMinutes(budget.interval, endingAt: resetsAt), reading: reading,
            alertName: "OpenRouter \(name)", usageText: usage
        ))
    }

    /// How long a budget's window is, for pace: the day, week or calendar
    /// month (UTC) before its reset. A budget whose interval is unreadable
    /// but that does reset is taken as monthly, OpenRouter's usual period.
    private static func windowMinutes(_ interval: String?, endingAt resetsAt: Date) -> Int {
        let component: Calendar.Component = switch interval {
        case "daily": .day
        case "weekly": .weekOfYear
        default: .month
        }
        guard let start = utc.date(byAdding: component, value: -1, to: resetsAt) else { return 30 * 1440 }
        return max(Int(resetsAt.timeIntervalSince(start) / 60), 1)
    }

    /// An ISO 8601 time, with or without fractional seconds.
    private static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
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
