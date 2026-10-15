import Foundation

/// GitHub Copilot, read with a fine-grained personal access token from
/// api.github.com and nowhere else. One poll is two or three requests:
///
/// 1. `GET /user`: the token's username. Any token can read it.
/// 2. `GET /users/{username}/settings/billing/premium_request/usage?year=&month=`,
///    documented (https://docs.github.com/en/rest/billing/usage), for this
///    UTC month; the token needs the "Plan" user permission (read). Its
///    answer, abridged:
///
///    ```json
///    { "timePeriod": { "year": 2026, "month": 10 }, "user": "mona",
///      "usageItems": [{ "product": "copilot", "sku": "copilot_premium_request", "model": "GPT-5",
///                       "unitType": "requests", "pricePerUnit": 0.04, "grossQuantity": 60, "grossAmount": 2.4,
///                       "discountQuantity": 60, "discountAmount": 2.4, "netQuantity": 0, "netAmount": 0 }] }
///    ```
///
///    It covers only a plan the user pays for: a seat from an organization
///    or enterprise is reported to it, so here the report is empty.
/// 3. With the "Premium requests meter" option on, the undocumented
///    `GET /copilot_internal/user`, which Copilot's own clients read:
///    `copilot_plan`, `quota_reset_date(_utc)` and
///    `quota_snapshots.premium_interactions{entitlement, remaining,
///    percent_remaining, unlimited}`. CodexBar reads it with an OAuth token;
///    GitHub's Copilot CLI accepts a fine-grained token with the "Copilot
///    Requests" permission, which is what this asks for.
///
/// `fetch` folds the answers into one body, which is what fixtures record:
///
/// ```json
/// { "user": { "login": "mona" }, "period": { "year": 2026, "month": 10 },
///   "billing": { "status": 200, "body": { … } },
///   "copilotInternal": { "status": 200, "body": { … } } }
/// ```
///
/// A refused `GET /user` is a rejected token; a 429, 5xx or network error on
/// it or the report keeps the last reading and backs off. Anything else the
/// report or the meter endpoint answers degrades only its own row, with a
/// note saying why.
public enum CopilotAPI: KeyAPI {
    public static let id = "copilot"
    public static let name = "GitHub Copilot"
    public static let symbol = "⊚"
    public static let systemImage = "airplane"
    public static let endpoint = URL(string: "https://api.github.com/user")!
    public static let keyHint: String? =
        "Create a fine-grained token at github.com/settings/personal-access-tokens with the Plan permission (read); the premium requests meter also needs Copilot Requests (read)"

    /// The meter from the undocumented `copilot_internal/user`.
    public static let meterOption = KeyOption(id: "copilotInternal", title: "Premium requests meter", detail: "Uses an undocumented GitHub endpoint")
    public static var options: [KeyOption] { [meterOption] }

    /// GitHub's documented REST API, as its docs ask for it.
    private static let restHeaders = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"]
    /// What Copilot's clients send to `copilot_internal`.
    private static let internalHeaders = ["Accept": "application/json", "X-GitHub-Api-Version": "2025-04-01"]

    // MARK: Fetch

    public static func fetch(_ client: KeyClient) async -> PollOutcome {
        let user = await client.get(endpoint, headers: restHeaders)
        guard case let .response(200, userBody, _) = user else { return user }
        guard let login = login(in: userBody) else { return .response(status: 200, body: Data("{}".utf8), retryAfter: nil) }

        let month = utc.dateComponents([.year, .month], from: client.startedAt)
        guard let year = month.year, let monthNumber = month.month,
              let reportURL = URL(string: "https://api.github.com/users/\(login)/settings/billing/premium_request/usage?year=\(year)&month=\(monthNumber)")
        else { return .response(status: 200, body: Data("{}".utf8), retryAfter: nil) }

        let report = await client.get(reportURL, headers: restHeaders)
        switch report {
        case .networkError, .blocked, .noCredentials:
            return report
        case let .response(status, _, _) where status == 401 || status == 429 || (500...599).contains(status):
            return report
        case .response:
            break
        }

        var combined: [String: Any] = [
            "user": ["login": login],
            "period": ["year": year, "month": monthNumber],
            "billing": part(report),
        ]
        if client.options.contains(meterOption.id) {
            combined["copilotInternal"] = part(await client.get(URL(string: "https://api.github.com/copilot_internal/user")!, headers: internalHeaders))
        }
        let body = (try? JSONSerialization.data(withJSONObject: combined)) ?? Data("{}".utf8)
        return .response(status: 200, body: body, retryAfter: nil)
    }

    /// The login from a `GET /user` answer, when it's one GitHub could have
    /// issued (letters, digits, hyphens; underscores for managed users), so
    /// it can go into a path as it is.
    private static func login(in body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let login = root["login"] as? String, (1...64).contains(login.count),
              login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return login
    }

    /// One answer as `{ "status": 200, "body": … }`; a network error has a
    /// null status. A body that isn't JSON is left out.
    private static func part(_ outcome: PollOutcome) -> [String: Any] {
        switch outcome {
        case let .response(status, body, _):
            var part: [String: Any] = ["status": status]
            if let json = try? JSONSerialization.jsonObject(with: body) { part["body"] = json }
            return part
        default:
            return ["status": NSNull()]
        }
    }

    // MARK: Reading

    public struct Reading: Equatable, Sendable {
        public var login: String?
        /// When the UTC month the report covers ends: midnight UTC on the
        /// next 1st.
        public var monthEnds: Date?
        public var billing: Billing
        /// Nil with the meter option off.
        public var quota: Quota?
    }

    /// What the premium request report said.
    public enum Billing: Equatable, Sendable {
        case usage(Usage)
        /// 403: the token lacks the Plan permission.
        case forbidden
        /// Another status (nil: no answer).
        case failed(Int?)
        /// A 200 without `usageItems`.
        case unreadable
    }

    public struct Usage: Equatable, Sendable {
        /// `grossQuantity`, all models.
        public var requests: Double = 0
        /// `grossAmount`: the requests at list price.
        public var listPrice: Double?
        /// `netAmount`: what's billed beyond the plan's allowance.
        public var billed: Double?
        /// Requests by model, most first.
        public var models: [ModelRequests] = []
    }

    public struct ModelRequests: Equatable, Sendable {
        public var model: String
        public var requests: Double
    }

    /// What `copilot_internal/user` said.
    public struct Quota: Equatable, Sendable {
        /// The answer's HTTP status; nil when there was none.
        public var status: Int?
        /// `copilot_plan`: "individual", "business", …
        public var plan: String?
        public var premium: Premium?
        /// The next reset: from the answer when it's plausible, else
        /// midnight UTC on the next 1st.
        public var resetsAt: Date?
        /// The window's length, for pace: the calendar month (UTC) before
        /// the reset.
        public var minutes: Int?
    }

    public enum Premium: Equatable, Sendable {
        case unlimited
        case limited(usedPercent: Double, used: Double?, entitlement: Double?)
    }

    public static func reading(fromResponse body: Data, receivedAt: Date) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let login = (root["user"] as? [String: Any])?["login"] as? String
        guard let billingPart = root["billing"] as? [String: Any] else { return nil }

        let period = root["period"] as? [String: Any]
        let monthEnds: Date? = {
            guard let year = Amount.number(period?["year"]).flatMap({ Int(exactly: $0) }),
                  let month = Amount.number(period?["month"]).flatMap({ Int(exactly: $0) }), (1...12).contains(month),
                  (2000...3000).contains(year) else { return nextFirst(after: receivedAt) }
            return utc.date(from: DateComponents(year: year, month: month + 1, day: 1))
        }()

        let meter = (root["copilotInternal"] as? [String: Any]).map { quota($0, receivedAt: receivedAt) }
        return Reading(login: login, monthEnds: monthEnds, billing: billing(billingPart), quota: meter)
    }

    private static func billing(_ part: [String: Any]) -> Billing {
        let status = Amount.number(part["status"]).flatMap { Int(exactly: $0) }
        guard status == 200 else { return status == 403 ? .forbidden : .failed(status) }
        guard let items = (part["body"] as? [String: Any])?["usageItems"] as? [Any] else { return .unreadable }
        var usage = Usage()
        var byModel: [String: Double] = [:]
        var order: [String] = []
        for case let item as [String: Any] in items {
            guard let requests = Amount.number(item["grossQuantity"]) else { continue }
            usage.requests += requests
            if let list = Amount.number(item["grossAmount"]) { usage.listPrice = (usage.listPrice ?? 0) + list }
            if let net = Amount.number(item["netAmount"]) { usage.billed = (usage.billed ?? 0) + net }
            let model = (item["model"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Other models"
            if byModel[model] == nil { order.append(model) }
            byModel[model, default: 0] += requests
        }
        // Most requests first; ties in the report's order.
        let models = order.map { ModelRequests(model: $0, requests: byModel[$0] ?? 0) }
        usage.models = models.enumerated().sorted { a, b in
            a.element.requests != b.element.requests ? a.element.requests > b.element.requests : a.offset < b.offset
        }.map(\.element)
        return .usage(usage)
    }

    private static func quota(_ part: [String: Any], receivedAt: Date) -> Quota {
        let status = Amount.number(part["status"]).flatMap { Int(exactly: $0) }
        var quota = Quota(status: status)
        guard status == 200, let body = part["body"] as? [String: Any] else { return quota }
        quota.plan = (body["copilot_plan"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

        let given = (body["quota_reset_date_utc"] as? String).flatMap(isoDate)
            ?? (body["quota_reset_date"] as? String).flatMap(dayDate)
        // A reset in the past or beyond next month is wrong: the next 1st.
        let resetsAt = given.flatMap { $0 > receivedAt && $0.timeIntervalSince(receivedAt) <= 32 * 86400 ? $0 : nil } ?? nextFirst(after: receivedAt)
        quota.resetsAt = resetsAt
        quota.minutes = resetsAt.flatMap { reset in
            utc.date(byAdding: .month, value: -1, to: reset).map { Int(reset.timeIntervalSince($0) / 60) }
        }

        guard let premium = (body["quota_snapshots"] as? [String: Any])?["premium_interactions"] as? [String: Any] else { return quota }
        if premium["unlimited"] as? Bool == true {
            quota.premium = .unlimited
            return quota
        }
        let entitlement = Amount.number(premium["entitlement"])
        let remaining = Amount.number(premium["remaining"])
        let used = entitlement.flatMap { entitlement in remaining.map { entitlement - $0 } }
        let percent = Amount.number(premium["percent_remaining"]).map { 100 - $0 }
            ?? entitlement.flatMap { entitlement in used.flatMap { entitlement > 0 ? $0 / entitlement * 100 : nil } }
        if let percent {
            quota.premium = .limited(usedPercent: min(max(percent, 0), 100), used: used, entitlement: entitlement)
        }
        return quota
    }

    // MARK: Report

    public static func report(_ reading: Reading?, clock: Clock) -> ProviderReport {
        var rows: [ProviderReport.Row] = []
        var notes: [String] = []
        let quota = reading?.quota
        let orgSeat = quota?.plan.map { ["business", "enterprise"].contains($0.lowercased()) } ?? false

        if let quota {
            rows.append(premiumRow(quota, clock: clock))
            switch quota.status {
            case 200 where quota.premium == nil:
                notes.append("Couldn't read the premium requests quota from GitHub's undocumented Copilot endpoint")
            case 200:
                break
            case let status? where [401, 403, 404].contains(status):
                notes.append("GitHub's undocumented Copilot endpoint answered HTTP \(status): give the token the Copilot Requests permission (read), or turn the meter off")
            case let status?:
                notes.append("GitHub's undocumented Copilot endpoint answered HTTP \(status)")
            case nil:
                notes.append("Couldn't reach GitHub's undocumented Copilot endpoint")
            }
        }

        var month = ValueRow(id: "copilot.month", label: "This month", value: nil)
        switch reading?.billing {
        case let .usage(usage)? where usage.models.isEmpty && orgSeat:
            notes.append("Your Copilot seat is billed to an organization, so GitHub reports its premium requests there")
        case let .usage(usage)?:
            // The UTC month the report covered has ended: it no longer holds.
            if let ends = reading?.monthEnds, ends > clock.now {
                month.value = Amount(usage.requests, .count("premium requests"))
                month.detail = detail(usage)
            }
            if usage.models.isEmpty {
                notes.append("Nothing billed to your personal account this month; a seat from an organization is reported to it")
            }
        case .forbidden?:
            notes.append("This token can't read billing: give it the Plan permission (read)")
        case .unreadable?:
            notes.append("Couldn't read the premium request usage from \(hostText)")
        case let .failed(status?)?:
            notes.append("\(hostText) answered HTTP \(status) for the premium request usage")
        case .failed(nil)?:
            notes.append("Couldn't read the premium request usage from \(hostText)")
        case nil:
            break
        }
        rows.append(.value(month))

        return ProviderReport(plan: quota?.plan.map(planBadge), rows: rows, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    private static func premiumRow(_ quota: Quota, clock: Clock) -> ProviderReport.Row {
        switch quota.premium {
        case .unlimited?:
            return .value(ValueRow(id: "copilot.premium", label: "Premium requests", value: nil, text: "Unlimited"))
        case let .limited(percent, used, entitlement)?:
            let reading = quota.resetsAt.map { LimitReading(usedPercent: percent, resetsAt: $0) }
            // The counts belong to the window they were read in.
            let usage: String? = if let used, let entitlement, (quota.resetsAt.map { $0 > clock.now } ?? true) {
                "\(Amount(used, .count("")).text) of \(Amount(entitlement, .count("")).text) used"
            } else {
                nil
            }
            return .window(window(reading: reading, minutes: quota.minutes, usage: usage))
        case nil:
            return .window(window(reading: nil, minutes: quota.minutes, usage: nil))
        }
    }

    private static func window(reading: LimitReading?, minutes: Int?, usage: String?) -> LimitWindow {
        LimitWindow(id: "copilot.premium", label: "Premium requests", minutes: minutes ?? 30 * 1440, reading: reading,
                    alertName: "Copilot premium requests limit", nearAlertName: "Copilot premium requests", usageText: usage)
    }

    /// "$8.56 at list price, nothing billed beyond the plan", then the
    /// requests by model.
    private static func detail(_ usage: Usage) -> String? {
        guard !usage.models.isEmpty else { return nil }
        let money: String? = switch (usage.listPrice, usage.billed) {
        case let (list?, billed?) where abs(list - billed) < 0.005: "\(Amount(billed, .usd).text) billed"
        case let (list?, billed?) where billed < 0.005: "\(Amount(list, .usd).text) at list price, nothing billed beyond the plan"
        case let (list?, billed?): "\(Amount(list, .usd).text) at list price, \(Amount(billed, .usd).text) billed"
        case let (list?, nil): "\(Amount(list, .usd).text) at list price"
        case let (nil, billed?): "\(Amount(billed, .usd).text) billed"
        case (nil, nil): nil
        }
        // Each model and its count wrap as one: "Claude Opus 4.1 230".
        let shown = usage.models.prefix(3).map { "\($0.model) \(Amount($0.requests, .count("")).text)".replacingOccurrences(of: " ", with: "\u{00A0}") }
        let rest = usage.models.count > 3 ? ["+\(usage.models.count - 3) more"] : []
        return ([money].compactMap(\.self) + [(shown + rest).joined(separator: " · ")]).joined(separator: "\n")
    }

    /// GitHub's names for Copilot's plans as they're sold.
    private static func planBadge(_ plan: String) -> String {
        switch plan.lowercased() {
        case "free": "Free"
        case "individual": "Pro"
        case "individual_pro": "Pro+"
        case "business": "Business"
        case "enterprise": "Enterprise"
        default: plan.split(whereSeparator: { $0 == "_" || $0 == " " }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    public static func shift(_ reading: Reading, by offset: TimeInterval) -> Reading {
        var copy = reading
        copy.monthEnds = reading.monthEnds.map { $0 + offset }
        copy.quota?.resetsAt = reading.quota?.resetsAt.map { $0 + offset }
        return copy
    }

    // MARK: Time

    /// GitHub's billing months and Copilot's quotas follow UTC.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Midnight UTC on the first 1st after `date`.
    static func nextFirst(after date: Date) -> Date? {
        utc.nextDate(after: date, matching: DateComponents(day: 1, hour: 0, minute: 0, second: 0), matchingPolicy: .strict)
    }

    /// "2026-11-01T00:00:00.000Z", with or without fractional seconds.
    private static func isoDate(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    /// "2026-11-01" at midnight UTC.
    private static func dayDate(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
