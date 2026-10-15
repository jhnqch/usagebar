import Foundation

/// The z.ai GLM Coding Plan's limits, read from the undocumented
/// `GET /api/monitor/usage/quota/limit` with the user's API key. z.ai's own
/// ZCode app documents it (zai-org/ZCode
/// docs/bigmodel-coding-plan-usage-quota.md); CodexBar reads it too.
///
/// Its answer:
///
/// ```json
/// { "code": 200, "msg": "…", "success": true,
///   "data": { "level": "pro", "limits": [
///     { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 72, "nextResetTime": 1791676680000 },
///     { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 41, "nextResetTime": 1791900000000 },
///     { "type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 1000, "currentValue": 224, "remaining": 776,
///       "percentage": 22, "nextResetTime": 1793589300000, "usageDetails": [ … ] } ] } }
/// ```
///
/// - Each of `limits[]` is a limit window, so it gets pace, a share of the
///   menu bar and the 90% and reset alerts. `TOKENS_LIMIT` (and the
///   `CREDIT_LIMIT` some plans send) are the prompt windows; `TIME_LIMIT`
///   is the monthly MCP tools quota, which blocks only tools and so stays
///   out of the menu bar. An entry of any other type still gets a meter.
/// - `percentage` is the percent used. With `usage` (the total) and
///   `currentValue` or `remaining`, the counts give it more exactly.
/// - The window's length is `number` of `unit`: 1 day, 3 hours, 5 months,
///   6 weeks. Without a known unit it's inferred: `TIME_LIMIT` is monthly,
///   others from how far off the reset is (within 5 hours: the 5-hour
///   window; within a week: weekly; beyond: monthly).
/// - `nextResetTime` is epoch milliseconds, so it needs no time zone. It's
///   optional; without it, or when it lies further off than the window is
///   long (no time zone correction is guessed), the meter shows the percent
///   without a reset, pace or alerts.
/// - `level` (or `planName`, `plan`, `plan_type`, `packageName`) is the
///   plan badge.
/// - A rejected key comes back as HTTP 200 with `success: false` and
///   `code: 401`; an account without a Coding Plan as `code: 500` and a
///   message saying so. `interpret` turns the body's code into the status.
/// - The key goes in the `Authorization` header as it is, without
///   `Bearer`: ZCode's docs say the prefix fails authentication.
///
/// z.ai (api.z.ai) and BigModel, its China platform (open.bigmodel.cn),
/// are each their own provider with their own key and one pinned host:
/// `ZaiAPI` and `BigModelAPI`.
public protocol ZaiPlatformAPI: KeyAPI where Reading == ZaiQuota {}

/// What a quota answer says.
public struct ZaiQuota: Equatable, Sendable {
    /// The plan badge's text, as sent: "pro".
    public var plan: String?
    /// The readable entries, shortest window first, MCP and unknown types
    /// after.
    public var limits: [Limit] = []
    /// The answer says the key's account has no Coding Plan.
    public var noPlan = false
    /// Entries that weren't objects with a percent or counts.
    public var unreadableEntries = 0

    /// One `limits[]` entry.
    public struct Limit: Equatable, Sendable {
        /// `type`: "TOKENS_LIMIT", "TIME_LIMIT", or anything new.
        public var type: String?
        /// The window's length, worked out once from the answer so a
        /// rebased fixture keeps it; nil when it can't be told.
        public var length: Length?
        public var usedPercent: Double?
        /// Nil when not given, or when it lies further off than the window
        /// is long.
        public var resetsAt: Date?
        /// Whether a reset was given but looked wrong.
        public var resetHidden = false
        /// Its place among the answer's entries of the same kind, in the
        /// answer's order: names its window, which must stay the same from
        /// poll to poll even when its length is guessed (from a reset that
        /// draws nearer) or its unit goes missing.
        public var ordinal = 0
        /// `currentValue` (or `usage - remaining`) and `usage`.
        public var used: Double?
        public var total: Double?
    }

    /// A window's length as the answer counts it: 5 hours, 1 week, 1 month.
    public struct Length: Equatable, Sendable {
        public enum Unit: String, Sendable { case hour = "h", day = "d", week = "w", month = "mo" }
        public var count: Int
        public var unit: Unit
        /// In minutes, for pace. A month is the calendar month (UTC) before
        /// the reset, or 30 days without one.
        public var minutes: Int
    }
}

extension ZaiPlatformAPI {
    public static func authorization(key: String) -> String { key }
    public static var hasLimitWindows: Bool { true }

    /// A 200 whose body says the key was rejected, or that the server
    /// failed, as that status, so the usual policy applies: "Key rejected",
    /// or keep the last reading and back off.
    public static func interpret(_ outcome: PollOutcome) -> PollOutcome {
        guard case let .response(200, body, retryAfter) = outcome,
              let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              root["success"] as? Bool != true,
              let code = (root["code"] as? NSNumber).map(\.intValue) else { return outcome }
        switch code {
        case 401, 403, 429: return .response(status: code, body: body, retryAfter: retryAfter)
        case 500...599 where !saysNoPlan(root): return .response(status: code, body: body, retryAfter: retryAfter)
        default: return outcome
        }
    }

    /// "当前用户不存在coding plan" on BigModel, in English on z.ai.
    private static func saysNoPlan(_ root: [String: Any]) -> Bool {
        (root["msg"] as? String)?.lowercased().contains("coding plan") == true
    }

    public static func reading(fromResponse body: Data, receivedAt: Date) -> ZaiQuota? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        if root["success"] as? Bool == false {
            return saysNoPlan(root) ? ZaiQuota(noPlan: true) : nil
        }
        guard let data = root["data"] as? [String: Any], let entries = data["limits"] as? [Any] else { return nil }
        let plan = ["level", "planName", "plan", "plan_type", "packageName"].lazy
            .compactMap { (data[$0] as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        var quota = ZaiQuota(plan: plan)
        var counts: [String: Int] = [:]
        for entry in entries {
            if var limit = limit(entry, receivedAt: receivedAt) {
                let key = idBase(limit.type)
                limit.ordinal = counts[key, default: 0]
                counts[key] = limit.ordinal + 1
                quota.limits.append(limit)
            } else {
                quota.unreadableEntries += 1
            }
        }
        quota.limits = quota.limits.enumerated().sorted { a, b in
            (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element)
        return quota
    }

    /// What a window's id starts with after the provider's: "tokens",
    /// "mcp", or the unknown type's name.
    private static func idBase(_ type: String?) -> String {
        switch Kind(type) {
        case .prompts: "tokens"
        case .tools: "mcp"
        case .other: (type ?? "unknown").lowercased()
        }
    }

    /// Prompt windows first, shortest first; then MCP, then anything else.
    private static func rank(_ limit: ZaiQuota.Limit) -> Int {
        let minutes = limit.length?.minutes ?? Int.max / 4
        switch Kind(limit.type) {
        case .prompts: return minutes
        case .tools: return Int.max / 2
        case .other: return Int.max / 2 + 1
        }
    }

    private static func limit(_ element: Any, receivedAt: Date) -> ZaiQuota.Limit? {
        guard let entry = element as? [String: Any] else { return nil }
        let type = entry["type"] as? String
        let total = Amount.number(entry["usage"])
        let remaining = Amount.number(entry["remaining"])
        let used = Amount.number(entry["currentValue"]) ?? total.flatMap { total in remaining.map { total - $0 } }
        let counted = total.flatMap { total in used.map { total > 0 ? $0 / total * 100 : nil } } ?? nil
        let percent = (counted ?? Amount.number(entry["percentage"])).map { min(max($0, 0), 100) }
        guard percent != nil || type != nil else { return nil }

        // Epoch milliseconds; anything outside 1970 to about 2286 is junk.
        let reset = Amount.number(entry["nextResetTime"]).flatMap { $0 > 0 && $0 < 1e13 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        let length = length(unit: entry["unit"], number: entry["number"], type: type, resetsAt: reset, receivedAt: receivedAt)
        // A reset further off than the window is long is wrong (a time zone
        // mix-up, a cached value): show the percent without it.
        let plausible = reset.map { reset in
            length.map { reset.timeIntervalSince(receivedAt) <= TimeInterval($0.minutes * 60 + 60) } ?? true
        } ?? true
        return ZaiQuota.Limit(type: type, length: length, usedPercent: percent, resetsAt: plausible ? reset : nil,
                              resetHidden: !plausible, used: used, total: total)
    }

    /// `number` of `unit`, or inferred from the type and the reset's
    /// distance.
    private static func length(unit: Any?, number: Any?, type: String?, resetsAt: Date?, receivedAt: Date) -> ZaiQuota.Length? {
        let units: [Int: ZaiQuota.Length.Unit] = [1: .day, 3: .hour, 5: .month, 6: .week]
        // Whole numbers in a sane range only, so the arithmetic can't trap.
        if let code = Amount.number(unit).flatMap({ Int(exactly: $0) }), let unit = units[code],
           let count = Amount.number(number).flatMap({ Int(exactly: $0) }), (1...1000).contains(count) {
            return makeLength(count, unit, resetsAt: resetsAt)
        }
        if Kind(type) == .tools { return makeLength(1, .month, resetsAt: resetsAt) }
        guard let resetsAt else { return nil }
        let distance = resetsAt.timeIntervalSince(receivedAt)
        return if distance <= 5 * 3600 + 60 {
            makeLength(5, .hour, resetsAt: resetsAt)
        } else if distance <= 7 * 86400 + 60 {
            makeLength(1, .week, resetsAt: resetsAt)
        } else {
            makeLength(1, .month, resetsAt: resetsAt)
        }
    }

    private static func makeLength(_ count: Int, _ unit: ZaiQuota.Length.Unit, resetsAt: Date?) -> ZaiQuota.Length {
        let minutes: Int = switch unit {
        case .hour: count * 60
        case .day: count * 1440
        case .week: count * 10080
        case .month:
            resetsAt.flatMap { reset in
                utc.date(byAdding: .month, value: -count, to: reset).map { Int(reset.timeIntervalSince($0) / 60) }
            } ?? count * 30 * 1440
        }
        return ZaiQuota.Length(count: count, unit: unit, minutes: minutes)
    }

    public static func report(_ reading: ZaiQuota?, clock: Clock) -> ProviderReport {
        guard let reading, !reading.limits.isEmpty else {
            let rows: [ProviderReport.Row] = [
                .window(LimitWindow(id: "\(id).tokens.0", label: "5-hour", minutes: 300, reading: nil, alertName: "\(name) 5-hour limit")),
                .window(LimitWindow(id: "\(id).tokens.1", label: "Weekly", minutes: 10080, reading: nil, alertName: "\(name) weekly limit")),
            ]
            let note: String? = switch reading {
            case nil: nil
            case let quota? where quota.noPlan: "No GLM Coding Plan on this key"
            case let quota? where quota.unreadableEntries > 0: "Couldn't read the quota limits from \(hostText)"
            default: "The answer from \(hostText) had no quota limits"
            }
            return ProviderReport(plan: reading?.plan.map(UsageEngine.planBadge), rows: rows, note: note)
        }

        var ids: Set<String> = []
        let rows = reading.limits.map { limit in ProviderReport.Row.window(window(limit, ids: &ids, clock: clock)) }
        let note: String? = if reading.unreadableEntries > 0 {
            "Some quota limits couldn't be read"
        } else if reading.limits.contains(where: \.resetHidden) {
            "A reset time from \(hostText) looked wrong, so it's hidden"
        } else {
            nil
        }
        return ProviderReport(plan: reading.plan.map(UsageEngine.planBadge), rows: rows, note: note)
    }

    private static func window(_ limit: ZaiQuota.Limit, ids: inout Set<String>, clock: Clock) -> LimitWindow {
        let kind = Kind(limit.type)
        let lengthName: String? = limit.length.map { length in
            switch (length.count, length.unit) {
            case (1, .day): "Daily"
            case (1, .week): "Weekly"
            case (1, .month): "Monthly"
            case let (count, unit): "\(count)-\(["h": "hour", "d": "day", "w": "week", "mo": "month"][unit.rawValue]!)"
            }
        }
        let lengthKey = limit.length.map { "\($0.count)\($0.unit.rawValue)" }
        let label = switch kind {
        case .prompts: lengthName ?? "Quota"
        case .tools: lengthKey == "1mo" || lengthName == nil ? "MCP tools" : "MCP tools · \(lengthName!)"
        case .other: lengthName.map { "\($0) quota" } ?? "Quota"
        }
        // Known by kind and place, not length, which can be guessed.
        let base = "\(idBase(limit.type)).\(limit.ordinal)"
        var windowID = "\(id).\(base)"
        var suffix = 2
        while !ids.insert(windowID).inserted {
            windowID = "\(id).\(base).\(suffix)"
            suffix += 1
        }

        let reading = limit.usedPercent.flatMap { percent in limit.resetsAt.map { LimitReading(usedPercent: percent, resetsAt: $0) } }
        // The counts belong to the window they were read in.
        let usage: String? = if let used = limit.used, let total = limit.total, (limit.resetsAt.map { $0 > clock.now } ?? true) {
            "\(Amount(used, .count("")).text) of \(Amount(total, .count(kind == .tools ? "calls" : "")).text) used"
        } else {
            nil
        }
        let spoken = kind == .tools ? label : label.prefix(1).lowercased() + label.dropFirst()
        return LimitWindow(
            id: windowID, label: label, minutes: limit.length?.minutes ?? 0, reading: reading,
            alertName: "\(name) \(spoken) limit", nearAlertName: "\(name) \(spoken) quota",
            inMenuBar: kind == .prompts, usageText: usage,
            percentWithoutReset: reading == nil ? limit.usedPercent : nil
        )
    }

    public static func shift(_ reading: ZaiQuota, by offset: TimeInterval) -> ZaiQuota {
        var copy = reading
        copy.limits = reading.limits.map { limit in
            var moved = limit
            moved.resetsAt = limit.resetsAt.map { $0 + offset }
            return moved
        }
        return copy
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

/// What a limit entry's `type` limits.
private enum Kind {
    /// `TOKENS_LIMIT`, or `CREDIT_LIMIT` on points-based plans: prompts.
    case prompts
    /// `TIME_LIMIT`: MCP tool calls.
    case tools
    case other

    init(_ type: String?) {
        switch type?.uppercased() {
        case "TOKENS_LIMIT", "CREDIT_LIMIT": self = .prompts
        case "TIME_LIMIT": self = .tools
        default: self = .other
        }
    }
}

/// z.ai's international platform: api.z.ai.
public enum ZaiAPI: ZaiPlatformAPI {
    public static let id = "zai"
    public static let name = "z.ai"
    public static let symbol = "ℤ"
    public static let systemImage = "z.circle"
    public static let endpoint = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    public static let keyHint: String? = "Create a key at z.ai/manage-apikey/apikey-list"
}

/// BigModel, z.ai's China platform: open.bigmodel.cn.
public enum BigModelAPI: ZaiPlatformAPI {
    public static let id = "bigmodel"
    public static let name = "BigModel"
    public static let symbol = "ℤ"
    public static let systemImage = "z.circle"
    public static let endpoint = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    public static let keyHint: String? = "Create a key at bigmodel.cn/usercenter/proj-mgmt/apikeys"
}
