import Foundation

/// GitHub Copilot, read with a fine-grained personal access token from
/// api.github.com and nowhere else. One poll is three or four requests:
///
/// 1. `GET /user`: the token's username. Any token can read it.
/// 2. `GET /users/{username}/settings/billing/ai_credit/usage?year=&month=`
///    and
/// 3. `GET /users/{username}/settings/billing/premium_request/usage?year=&month=`,
///    both documented (https://docs.github.com/en/rest/billing/usage), for
///    this UTC month; the token needs the "Plan" user permission (read).
///    Since 1 June 2026 Copilot bills in AI credits (1 credit = $0.01);
///    only annual Pro and Pro+ plans that stayed on the old billing still
///    count premium requests. Both answers look like this, abridged:
///
///    ```json
///    { "timePeriod": { "year": 2026, "month": 10 }, "user": "mona",
///      "usageItems": [{ "product": "copilot", "sku": "copilot_premium_request", "model": "GPT-5",
///                       "unitType": "requests", "pricePerUnit": 0.04, "grossQuantity": 60, "grossAmount": 2.4,
///                       "discountQuantity": 60, "discountAmount": 2.4, "netQuantity": 0, "netAmount": 0 }] }
///    ```
///
///    They cover only a plan the user pays for: a seat from an organization
///    or enterprise is reported to it, so here the reports are empty.
/// 4. With the "Quota meter and plan" option on, the undocumented
///    `GET /copilot_internal/user`, which Copilot's own clients read:
///    `copilot_plan`, `token_based_billing`, `quota_reset_date(_utc)` and
///    `quota_snapshots.premium_interactions{entitlement, remaining,
///    percent_remaining, unlimited, credits_used}`. On premium-request
///    billing that's a meter (or "Unlimited"); on AI-credit billing it gives
///    no limit, only the credits a seat used. CodexBar reads it with an
///    OAuth token; GitHub's Copilot CLI accepts a fine-grained token with
///    the "Copilot Requests" permission, which is what this asks for.
///
/// `fetch` folds the answers into one body, which is what fixtures record:
///
/// ```json
/// { "user": { "login": "mona" }, "period": { "year": 2026, "month": 10 },
///   "aiCredits": { "status": 200, "body": { … } },
///   "billing": { "status": 200, "body": { … } },
///   "copilotInternal": { "status": 200, "body": { … } } }
/// ```
///
/// A refused `GET /user` is a rejected token; a 429, 5xx or network error on
/// it or a report keeps the last reading and backs off. Anything else a
/// report or the meter endpoint answers degrades only its own row, with a
/// note saying why.
public enum CopilotAPI: KeyAPI {
    public static let id = "copilot"
    public static let name = "GitHub Copilot"
    public static let symbol = "⊚"
    public static let systemImage = "airplane"
    public static let endpoint = URL(string: "https://api.github.com/user")!
    public static let keyHint: String? =
        "Create a fine-grained token at github.com/settings/personal-access-tokens with the Plan permission (read); the quota meter also needs Copilot Requests (read)"

    /// The meter and plan badge from the undocumented `copilot_internal/user`.
    public static let meterOption = KeyOption(id: "copilotInternal", title: "Quota meter and plan", detail: "Uses an undocumented GitHub endpoint")
    public static var options: [KeyOption] { [meterOption] }

    /// GitHub's documented REST API, as its docs ask for it.
    private static let restHeaders = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"]
    /// What Copilot's clients send to `copilot_internal`.
    private static let internalHeaders = ["Accept": "application/json", "X-GitHub-Api-Version": "2025-04-01"]

    // MARK: Fetch

    public static func fetch(_ client: KeyClient) async -> PollOutcome {
        let user = rateLimitAsTransient(await client.get(endpoint, headers: restHeaders))
        guard case let .response(200, userBody, _) = user else { return user }
        guard let login = login(in: userBody) else { return .response(status: 200, body: Data("{}".utf8), retryAfter: nil) }

        let month = utc.dateComponents([.year, .month], from: client.startedAt)
        guard let year = month.year, let monthNumber = month.month else { return .response(status: 200, body: Data("{}".utf8), retryAfter: nil) }

        var combined: [String: Any] = [
            "user": ["login": login],
            "period": ["year": year, "month": monthNumber],
        ]
        for (key, report) in [("aiCredits", "ai_credit"), ("billing", "premium_request")] {
            guard let url = URL(string: "https://api.github.com/users/\(login)/settings/billing/\(report)/usage?year=\(year)&month=\(monthNumber)")
            else { return .response(status: 200, body: Data("{}".utf8), retryAfter: nil) }
            let answer = rateLimitAsTransient(await client.get(url, headers: restHeaders))
            switch answer {
            case .networkError, .blocked, .noCredentials:
                return answer
            case let .response(status, _, _) where status == 401 || status == 429 || (500...599).contains(status):
                return answer
            case .response:
                combined[key] = part(answer)
            }
        }
        if client.options.contains(meterOption.id) {
            combined["copilotInternal"] = part(await client.get(URL(string: "https://api.github.com/copilot_internal/user")!, headers: internalHeaders))
        }
        let body = (try? JSONSerialization.data(withJSONObject: combined)) ?? Data("{}".utf8)
        return .response(status: 200, body: body, retryAfter: nil)
    }

    /// GitHub answers a used-up rate limit with 403 as often as 429: as
    /// 429, it keeps the last reading and backs off instead of reading as a
    /// refused token.
    private static func rateLimitAsTransient(_ outcome: PollOutcome) -> PollOutcome {
        guard case let .response(403, body, retryAfter) = outcome,
              let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String,
              message.lowercased().contains("rate limit") else { return outcome }
        return .response(status: 429, body: body, retryAfter: retryAfter)
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

    /// With the meter option off, the meter's reading goes at once, rather
    /// than when the next answer comes.
    public static func applying(options: Set<String>, to reading: Reading) -> Reading {
        guard !options.contains(meterOption.id) else { return reading }
        var copy = reading
        copy.quota = nil
        return copy
    }

    /// A token that can read neither report shows nothing useful.
    public static func connectionProblem(_ reading: Reading) -> String? {
        guard reading.aiCredits.usage == nil, reading.premiumRequests.usage == nil else { return nil }
        return reading.aiCredits == .forbidden || reading.premiumRequests == .forbidden
            ? forbiddenNote : "Couldn't read the usage reports from \(hostText)"
    }

    // MARK: Reading

    public struct Reading: Equatable, Sendable {
        public var login: String?
        /// When the UTC month the reports cover ends: midnight UTC on the
        /// next 1st.
        public var monthEnds: Date?
        /// The AI credit report: empty when the answer had none.
        public var aiCredits: Billing
        /// The premium request report (old billing).
        public var premiumRequests: Billing
        /// Nil with the meter option off.
        public var quota: Quota?
    }

    /// What a usage report said.
    public enum Billing: Equatable, Sendable {
        case usage(Usage)
        /// 403: the token lacks the Plan permission.
        case forbidden
        /// Another status (nil: no answer).
        case failed(Int?)
        /// A 200 without readable `usageItems`.
        case unreadable

        var usage: Usage? {
            if case let .usage(usage) = self { usage } else { nil }
        }
    }

    public struct Usage: Equatable, Sendable {
        /// `grossQuantity`, all models: credits or requests.
        public var quantity: Double = 0
        /// `grossAmount`: the usage at list price.
        public var listPrice: Double?
        /// `netAmount`: what's billed beyond the plan's allowance.
        public var billed: Double?
        /// Quantity by model, most first.
        public var models: [ModelUsage] = []
    }

    public struct ModelUsage: Equatable, Sendable {
        public var model: String
        public var quantity: Double
    }

    /// What `copilot_internal/user` said.
    public struct Quota: Equatable, Sendable {
        /// The answer's HTTP status; nil when there was none.
        public var status: Int?
        /// `copilot_plan`: "individual", "business", …
        public var plan: String?
        /// On AI-credit billing (`token_based_billing`, or a premium
        /// snapshot of zeros): no limit to meter.
        public var creditBilling = false
        /// `credits_used` on AI-credit billing.
        public var creditsUsed: Double?
        /// The meter's limit is in AI credits, not premium requests.
        public var creditLimit = false
        public var premium: Premium?
        /// The reset: from the answer when it's plausible, else midnight UTC
        /// on the next 1st.
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
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let premiumPart = root["billing"] as? [String: Any] else { return nil }
        let login = (root["user"] as? [String: Any])?["login"] as? String

        let period = root["period"] as? [String: Any]
        let monthEnds: Date? = {
            guard let year = Amount.number(period?["year"]).flatMap({ Int(exactly: $0) }),
                  let month = Amount.number(period?["month"]).flatMap({ Int(exactly: $0) }), (1...12).contains(month),
                  (2000...3000).contains(year) else { return nextFirst(after: receivedAt) }
            return utc.date(from: DateComponents(year: year, month: month + 1, day: 1))
        }()

        let meter = (root["copilotInternal"] as? [String: Any]).map { quota($0, receivedAt: receivedAt) }
        let credits = (root["aiCredits"] as? [String: Any]).map(billing) ?? .usage(Usage())
        return Reading(login: login, monthEnds: monthEnds, aiCredits: credits, premiumRequests: billing(premiumPart), quota: meter)
    }

    private static func billing(_ part: [String: Any]) -> Billing {
        let status = Amount.number(part["status"]).flatMap { Int(exactly: $0) }
        guard status == 200 else { return status == 403 ? .forbidden : .failed(status) }
        guard let items = (part["body"] as? [String: Any])?["usageItems"] as? [Any] else { return .unreadable }
        var usage = Usage()
        var byModel: [String: Double] = [:]
        var order: [String] = []
        for element in items {
            // A total missing an item would look right and be wrong.
            guard let item = element as? [String: Any], let quantity = Amount.number(item["grossQuantity"]) else { return .unreadable }
            usage.quantity += quantity
            if let list = Amount.number(item["grossAmount"]) { usage.listPrice = (usage.listPrice ?? 0) + list }
            if let net = Amount.number(item["netAmount"]) { usage.billed = (usage.billed ?? 0) + net }
            let model = (item["model"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Other models"
            if byModel[model] == nil { order.append(model) }
            byModel[model, default: 0] += quantity
        }
        // Most first; ties in the report's order.
        let models = order.map { ModelUsage(model: $0, quantity: byModel[$0] ?? 0) }
        usage.models = models.enumerated().sorted { a, b in
            a.element.quantity != b.element.quantity ? a.element.quantity > b.element.quantity : a.offset < b.offset
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
        // A reset more than a day before the answer, or beyond next month,
        // is wrong: the next 1st. One just passed (the month turned while
        // the answer was on its way) stays, so the meter reads 0%.
        let resetsAt = given.flatMap {
            $0.timeIntervalSince(receivedAt) > -86400 && $0.timeIntervalSince(receivedAt) <= 32 * 86400 ? $0 : nil
        } ?? nextFirst(after: receivedAt)
        quota.resetsAt = resetsAt
        quota.minutes = resetsAt.flatMap { reset in
            utc.date(byAdding: .month, value: -1, to: reset).map { Int(reset.timeIntervalSince($0) / 60) }
        }

        guard let premium = (body["quota_snapshots"] as? [String: Any])?["premium_interactions"] as? [String: Any] else {
            quota.creditBilling = body["token_based_billing"] as? Bool == true
            return quota
        }
        let entitlement = Amount.number(premium["entitlement"])
        let remaining = Amount.number(premium["remaining"])
        quota.creditsUsed = Amount.number(premium["credits_used"])
        let tokenBased = body["token_based_billing"] as? Bool == true
        let unlimited = premium["unlimited"] as? Bool == true
        // A placeholder snapshot (zeros, and on AI-credit billing sometimes
        // marked unlimited) is no limit to meter. A real limit on AI-credit
        // billing is a meter of AI credits.
        if (!unlimited && entitlement == 0 && remaining == 0) || (tokenBased && (unlimited || !((entitlement ?? 0) > 0))) {
            quota.creditBilling = true
            return quota
        }
        quota.creditLimit = tokenBased
        if unlimited {
            quota.premium = .unlimited
            return quota
        }
        let used = entitlement.flatMap { entitlement in remaining.map { entitlement - $0 } }
        let percent = Amount.number(premium["percent_remaining"]).map { 100 - $0 }
            ?? entitlement.flatMap { entitlement in used.flatMap { entitlement > 0 ? $0 / entitlement * 100 : nil } }
        if let percent {
            quota.premium = .limited(usedPercent: min(max(percent, 0), 100), used: used, entitlement: entitlement)
        }
        return quota
    }

    // MARK: Report

    private static let forbiddenNote = "This token can't read billing: give it the Plan permission (read)"

    public static func report(_ reading: Reading?, clock: Clock) -> ProviderReport {
        var rows: [ProviderReport.Row] = []
        var notes: [String] = []
        let quota = reading?.quota
        let orgSeat = quota?.plan.map { ["business", "enterprise"].contains($0.lowercased()) } ?? false
        let credits = reading?.aiCredits.usage
        let requests = reading?.premiumRequests.usage
        let creditsEmpty = credits?.models.isEmpty ?? true
        let requestsEmpty = requests?.models.isEmpty ?? true
        // The reports belong to a UTC month; once it ends they no longer hold.
        let monthHolds = reading?.monthEnds.map { $0 > clock.now } ?? false

        if let quota {
            if quota.creditBilling {
                // A seat's AI credits, where no report of the user's has them.
                if creditsEmpty, let used = quota.creditsUsed {
                    let holds = quota.resetsAt.map { $0 > clock.now } ?? true
                    rows.append(.value(ValueRow(id: "copilot.credits", label: "AI credits used", value: holds ? Amount(used, .count("")) : nil)))
                }
            } else if quota.status == 200 || quota.premium != nil {
                rows.append(premiumRow(quota, clock: clock))
            } else {
                rows.append(.window(window(reading: nil, minutes: quota.minutes, usage: nil)))
            }
            switch quota.status {
            case 200 where quota.premium == nil && !quota.creditBilling:
                notes.append("Couldn't read the quota from GitHub's undocumented Copilot endpoint")
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

        // AI credits, today's billing, unless only the old premium request
        // billing has anything.
        if !(creditsEmpty && !requestsEmpty) {
            var row = ValueRow(id: "copilot.month", label: "This month", value: nil)
            if let credits, monthHolds, !(creditsEmpty && orgSeat) {
                row.value = Amount(credits.quantity, .count("AI credits"))
                row.detail = detail(credits)
            }
            rows.append(.value(row))
        }
        if let requests, !requestsEmpty {
            rows.append(.value(ValueRow(id: "copilot.premiumRequests", label: "This month",
                                        value: monthHolds ? Amount(requests.quantity, .count("premium requests")) : nil,
                                        detail: detail(requests))))
        }

        if creditsEmpty && requestsEmpty && reading != nil {
            if reading?.aiCredits == .forbidden || reading?.premiumRequests == .forbidden {
                notes.append(forbiddenNote)
            } else if credits != nil && requests != nil {
                notes.append(orgSeat
                    ? "Your Copilot seat is billed to an organization, so GitHub reports its usage there"
                    : "Nothing billed to your personal account this month; a seat from an organization is reported to it")
            }
        }
        for (billing, what) in [(reading?.aiCredits, "AI credit"), (reading?.premiumRequests, "premium request")] {
            switch billing {
            case .unreadable?, .failed(nil)?: notes.append("Couldn't read the \(what) usage from \(hostText)")
            case let .failed(status?)?: notes.append("\(hostText) answered HTTP \(status) for the \(what) usage")
            default: break
            }
        }

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
            return .window(window(reading: reading, minutes: quota.minutes, usage: usage, credits: quota.creditLimit))
        case nil:
            return .window(window(reading: nil, minutes: quota.minutes, usage: nil))
        }
    }

    private static func window(reading: LimitReading?, minutes: Int?, usage: String?, credits: Bool = false) -> LimitWindow {
        let what = credits ? "AI credits" : "premium requests"
        return LimitWindow(id: credits ? "copilot.creditLimit" : "copilot.premium", label: credits ? "AI credits" : "Premium requests",
                           minutes: minutes ?? 30 * 1440, reading: reading,
                           alertName: "Copilot \(what) limit", nearAlertName: "Copilot \(what)", usageText: usage)
    }

    /// "$8.56 at list price, nothing billed beyond the plan", then the
    /// usage by model.
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
        let shown = usage.models.prefix(3).map { "\($0.model) \(Amount($0.quantity, .count("")).text)".replacingOccurrences(of: " ", with: "\u{00A0}") }
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
        guard parts.count == 3, let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        // Not a day that rolled over into another: 31 Feb isn't 3 Mar.
        let read = utc.dateComponents([.year, .month, .day], from: date)
        return [read.year, read.month, read.day] == [parts[0], parts[1], parts[2]] ? date : nil
    }
}
