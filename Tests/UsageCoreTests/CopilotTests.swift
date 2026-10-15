import Foundation
import Testing
import UsageCore

/// GitHub Copilot: the documented premium request usage report, and with the
/// meter option on the undocumented `copilot_internal/user`, from synthetic
/// fixtures of the body `CopilotAPI.fetch` builds, through the engine to what
/// the popover and menu bar show.
@Suite("GitHub Copilot")
struct CopilotTests {
    func snapshot(_ name: String) throws -> UsageSnapshot {
        let fixture = try loadFixture(name)
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone, selection: fixture.selection)
    }

    func meters(_ section: ProviderSection) -> [Meter] {
        section.rows.compactMap { row in
            if case let .meter(meter) = row { meter } else { nil }
        }
    }

    func values(_ section: ProviderSection) -> [ValueLine] {
        section.rows.compactMap { row in
            if case let .value(value) = row { value } else { nil }
        }
    }

    /// A detail line with its no-break spaces as plain ones.
    func detail(_ value: ValueLine?) -> String? {
        value?.detailText?.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// "label value · reset" per row.
    func texts(_ section: ProviderSection) -> [String] {
        section.rows.map { row in
            switch row {
            case let .meter(meter): "\(meter.label) \(meter.percentText)\(meter.resetText.map { " · \($0)" } ?? "")"
            case let .credit(credit): "\(credit.label) \(credit.valueText)"
            case let .value(value): "\(value.label) \(value.valueText)"
            }
        }
    }

    /// A fetched body for `copilot` received at `receivedAt`, read at `now`.
    func section(
        credits: String? = #"{ "status": 200, "body": { "usageItems": [] } }"#,
        billing: String? = #"{ "status": 200, "body": { "usageItems": [] } }"#, quota: String? = nil, user: String = #"{ "login": "mona-example" }"#,
        period: String = #"{ "year": 2026, "month": 10 }"#,
        now: String = "2026-10-14T10:00:00-07:00", receivedAt: String = "2026-10-14T09:58:00-07:00", timeZone: String = "America/Los_Angeles"
    ) throws -> ProviderSection {
        var parts = [#""user": \#(user)"#, #""period": \#(period)"#]
        if let credits { parts.append(#""aiCredits": \#(credits)"#) }
        if let billing { parts.append(#""billing": \#(billing)"#) }
        if let quota { parts.append(#""copilotInternal": \#(quota)"#) }
        let json = #"""
        { "now": "\#(now)", "timeZone": "\#(timeZone)", "readings": { "copilot": [
          { "receivedAt": "\#(receivedAt)", "status": 200, "body": { \#(parts.joined(separator: ", ")) } } ] } }
        """#
        let fixture = try Fixture.decode(Data(json.utf8))
        return try #require(UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)["copilot"])
    }

    /// A `copilot_internal/user` answer with the given premium snapshot.
    func internalAnswer(_ premium: String, extra: String = #", "quota_reset_date_utc": "2026-11-01T00:00:00.000Z""#, plan: String = "individual") -> String {
        #"{ "status": 200, "body": { "copilot_plan": "\#(plan)"\#(extra), "quota_snapshots": { "premium_interactions": \#(premium) } } }"#
    }

    @Test("a personal plan on AI-credit billing: this month's credits with per-model detail, and no meter, which GitHub gives no limit for")
    func personal() throws {
        let snapshot = try snapshot("copilot-personal")
        #expect(snapshot.sections.map(\.name) == ["GitHub Copilot"])
        let section = try #require(snapshot["copilot"])
        #expect(section.plan == "Pro")
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(texts(section) == ["This month 612.4 AI credits"])
        #expect(detail(values(section).first) == "$6.13 at list price, nothing billed beyond the plan\nClaude Sonnet 4.5 402.5 · GPT-5 150.9 · Gemini 2.5 Pro 59")
        #expect(section.note == nil)
        #expect(snapshot.menuBar.parts.isEmpty)
    }

    @Test("an annual plan on premium-request billing: a meter resetting on the 1st (UTC), and this month's requests with per-model detail")
    func legacyAnnual() throws {
        let snapshot = try snapshot("copilot-legacy-annual")
        #expect(snapshot.sections.map(\.name) == ["GitHub Copilot"])
        let section = try #require(snapshot["copilot"])
        #expect(section.plan == "Pro")
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(texts(section) == [
            // Midnight UTC on Sun 1 Nov is 5 PM on Sat 31 Oct in Los Angeles.
            "Premium requests 71% · Resets Sat Oct 31 5:00 PM",
            "This month 214 premium requests",
        ])
        let meter = try #require(meters(section).first)
        #expect(meter.usageText == "214 of 300 used")
        // 13 days 17 hours into October's 31 (UTC).
        #expect(meter.elapsedText == "44% of window elapsed")
        #expect(detail(values(section).first) == "$8.56 at list price, nothing billed beyond the plan\nClaude Sonnet 4.5 150 · GPT-5 60 · Gemini 2.5 Pro 4")
        // A model's name and count never split across lines.
        #expect(values(section).first?.detailText?.contains("Claude\u{00A0}Sonnet\u{00A0}4.5\u{00A0}150 · GPT-5") == true)
        #expect(section.note == nil)
        #expect(snapshot.menuBar.text == "⊚ 71%")
    }

    @Test("an organization's seat: the credits it used, the spend row a dash, and a note saying why")
    func orgSeat() throws {
        let section = try #require(try snapshot("copilot-org-seat")["copilot"])
        #expect(section.plan == "Business")
        #expect(texts(section) == ["AI credits used 45", "This month —"])
        #expect(section.note == "Your Copilot seat is billed to an organization, so GitHub reports its usage there")
    }

    @Test("on AI-credit billing a real limit is still a meter, of AI credits; a placeholder or unlimited one isn't")
    func creditQuota() throws {
        let tokenBased = #", "token_based_billing": true, "quota_reset_date_utc": "2026-11-01T00:00:00.000Z""#
        let limited = try section(quota: internalAnswer(#"{ "entitlement": 1500, "remaining": 900, "percent_remaining": 60, "unlimited": false, "credits_used": 600 }"#, extra: tokenBased))
        #expect(texts(limited) == ["AI credits 40% · Resets Sat Oct 31 5:00 PM", "This month 0 AI credits"])
        #expect(meters(limited).first?.usageText == "600 of 1,500 used")
        let unlimited = try section(quota: internalAnswer(#"{ "entitlement": 0, "remaining": 0, "unlimited": true, "credits_used": 31 }"#, extra: tokenBased))
        #expect(texts(unlimited) == ["AI credits used 31", "This month 0 AI credits"])
    }

    @Test("an unlimited plan shows Unlimited rather than a meter")
    func unlimited() throws {
        let snapshot = try snapshot("copilot-unlimited")
        let section = try #require(snapshot["copilot"])
        #expect(section.plan == "Pro")
        #expect(texts(section) == ["Premium requests Unlimited", "This month 1,842 premium requests"])
        #expect(meters(section).isEmpty)
        #expect(detail(values(section).last) == "$73.68 at list price, nothing billed beyond the plan\nClaude Sonnet 4.5 1,210 · GPT-5 402 · Claude Opus 4.1 230")
        // No window, so no menu bar share.
        #expect(snapshot.menuBar.parts.isEmpty)
    }

    @Test("with the meter option off there's no meter or plan, and an empty report says a seat from an organization isn't in it")
    func optionOff() throws {
        let section = try section()
        #expect(section.plan == nil)
        #expect(texts(section) == ["This month 0 AI credits"])
        #expect(section.note == "Nothing billed to your personal account this month; a seat from an organization is reported to it")
    }

    @Test("what's billed beyond the plan, and many models, read in the detail")
    func billed() throws {
        let items = [("GPT-5", 300, 300, 0), ("Claude Opus 4.1", 40, 0, 1.6), ("Gemini 2.5 Pro", 2, 0, 0.08), ("o3", 1, 0, 0.04), ("Grok Code", 1, 0, 0.04)]
            .map { #"{ "model": "\#($0.0)", "grossQuantity": \#($0.1), "grossAmount": \#(Double($0.1) * 0.04), "discountQuantity": \#($0.2), "netAmount": \#($0.3) }"# }
        let section = try section(billing: #"{ "status": 200, "body": { "usageItems": [\#(items.joined(separator: ","))] } }"#)
        #expect(texts(section) == ["This month 344 premium requests"])
        #expect(detail(values(section).first) == "$13.76 at list price, $1.76 billed\nGPT-5 300 · Claude Opus 4.1 40 · Gemini 2.5 Pro 2 · +2 more")

        let allBilled = try self.section(billing: #"{ "status": 200, "body": { "usageItems": [{ "model": "GPT-5", "grossQuantity": 5, "grossAmount": 0.2, "netAmount": 0.2 }] } }"#)
        #expect(detail(values(allBilled).first) == "$0.20 billed\nGPT-5 5")
    }

    @Test("the monthly reset is midnight UTC on the 1st, shown in local time on either side of a daylight saving change")
    func resetAcrossDST() throws {
        // No reset date in the answer: the next 1st, midnight UTC.
        let premium = #"{ "entitlement": 300, "remaining": 150, "unlimited": false }"#
        // London leaves summer time on Sun 25 Oct: October (UTC) began at 1 AM
        // BST and ends at midnight GMT, a 31-day window, not 31 days and an hour.
        let london = try section(quota: internalAnswer(premium, extra: ""),
                                 now: "2026-10-20T13:00:00+01:00", receivedAt: "2026-10-20T12:58:00+01:00", timeZone: "Europe/London")
        #expect(texts(london).first == "Premium requests 50% · Resets Sun Nov 1 12:00 AM")
        // 19.5 of 31 days.
        #expect(meters(london).first?.elapsedText == "63% of window elapsed")

        // Los Angeles leaves daylight time on Sun 1 Nov: October's reset
        // shows at 5 PM PDT, November's at 4 PM PST.
        let october = try section(quota: internalAnswer(premium, extra: ""))
        #expect(texts(october).first == "Premium requests 50% · Resets Sat Oct 31 5:00 PM")
        let november = try section(quota: internalAnswer(premium, extra: ""), period: #"{ "year": 2026, "month": 11 }"#,
                                   now: "2026-11-02T10:00:00-08:00", receivedAt: "2026-11-02T09:58:00-08:00")
        #expect(texts(november).first == "Premium requests 50% · Resets Mon Nov 30 4:00 PM")
    }

    @Test("this month's requests are October's in UTC: at 5 PM on 31 Oct in Los Angeles they no longer hold")
    func spendEndsWithTheUTCMonth() throws {
        let billing = #"{ "status": 200, "body": { "usageItems": [{ "model": "GPT-5", "grossQuantity": 5, "grossAmount": 0.2, "netAmount": 0 }] } }"#
        let before = try section(billing: billing, now: "2026-10-31T16:59:00-07:00")
        #expect(texts(before) == ["This month 5 premium requests"])
        let after = try section(billing: billing, now: "2026-10-31T17:00:00-07:00")
        #expect(texts(after) == ["This month —"])
    }

    @Test("a rebased fixture keeps the reading where it sat")
    func rebased() throws {
        let fixture = try loadFixture("copilot-legacy-annual")
        let later = fixture.now + 86400
        let section = try #require(UsageEngine.snapshot(from: fixture.readings(rebasedTo: later), now: later, timeZone: fixture.timeZone)["copilot"])
        #expect(section.updatedText == "Updated 2 min ago")
        // 24 hours later in absolute time, past the end of daylight saving.
        #expect(texts(section) == ["Premium requests 71% · Resets Sun Nov 1 4:00 PM", "This month 214 premium requests"])
    }

    @Test("the reset date: the UTC time, else the date at midnight UTC, else the next 1st; one that looks wrong is replaced")
    func resetDates() throws {
        let premium = #"{ "entitlement": 300, "remaining": 150, "percent_remaining": 50, "unlimited": false }"#
        let dateOnly = try section(quota: internalAnswer(premium, extra: #", "quota_reset_date": "2026-11-01""#))
        #expect(texts(dateOnly).first == "Premium requests 50% · Resets Sat Oct 31 5:00 PM")
        let farOff = try section(quota: internalAnswer(premium, extra: #", "quota_reset_date_utc": "2027-05-01T00:00:00Z""#))
        #expect(texts(farOff).first == "Premium requests 50% · Resets Sat Oct 31 5:00 PM")
        let past = try section(quota: internalAnswer(premium, extra: #", "quota_reset_date": "2026-09-01""#))
        #expect(texts(past).first == "Premium requests 50% · Resets Sat Oct 31 5:00 PM")
        let junk = try section(quota: internalAnswer(premium, extra: #", "quota_reset_date_utc": 7"#))
        #expect(texts(junk).first == "Premium requests 50% · Resets Sat Oct 31 5:00 PM")
    }

    /// The answer left just before midnight UTC on 1 Nov and arrived just
    /// after: its reset has passed, so the full meter is last month's.
    @Test("a reset that passed while the answer was on its way stays, so the meter reads 0% rather than full for another month")
    func resetJustPassed() throws {
        let full = #"{ "entitlement": 300, "remaining": 0, "percent_remaining": 0, "unlimited": false }"#
        let section = try section(quota: internalAnswer(full), now: "2026-10-31T17:02:00-07:00", receivedAt: "2026-10-31T17:00:30-07:00")
        #expect(texts(section).first == "Premium requests 0% · Reset at 5:00 PM")
        #expect(meters(section).first?.usageText == nil)
    }

    @Test("the percent comes from percent_remaining, or the counts; past the entitlement it reads 100%")
    func percents() throws {
        let counts = try section(quota: internalAnswer(#"{ "entitlement": "300", "remaining": 75 }"#))
        #expect(texts(counts).first == "Premium requests 75% · Resets Sat Oct 31 5:00 PM")
        let over = try section(quota: internalAnswer(#"{ "entitlement": 300, "remaining": -12, "percent_remaining": -4, "overage_count": 12 }"#))
        #expect(texts(over).first == "Premium requests 100% · Resets Sat Oct 31 5:00 PM")
        #expect(meters(over).first?.usageText == "312 of 300 used")
    }

    @Test("missing or renamed fields degrade only their own row")
    func tolerant() throws {
        let noPremium = try section(quota: #"{ "status": 200, "body": { "copilot_plan": "individual", "quota_snapshots": {} } }"#)
        #expect(noPremium.plan == "Pro")
        #expect(texts(noPremium) == ["Premium requests —", "This month 0 AI credits"])
        #expect(noPremium.note?.contains("Couldn't read the quota") == true)

        let renamed = try section(credits: #"{ "status": 200, "body": { "items": [] } }"#)
        #expect(texts(renamed) == ["This month —"])
        #expect(renamed.note == "Couldn't read the AI credit usage from api.github.com")

        // Items, but no count in any: unknown, not zero.
        let noCounts = try section(credits: #"{ "status": 200, "body": { "usageItems": [{ "model": "GPT-5", "quantity": 12 }] } }"#)
        #expect(texts(noCounts) == ["This month —"])
        #expect(noCounts.note == "Couldn't read the AI credit usage from api.github.com")

        let oddItems = try section(billing: #"{ "status": 200, "body": { "usageItems": [7, { "model": "GPT-5" }, { "grossQuantity": 3, "grossAmount": 0.12 }, null] } }"#)
        #expect(texts(oddItems) == ["This month 3 premium requests"])
        #expect(detail(values(oddItems).first) == "$0.12 at list price\nOther models 3")

        let unknownPlan = try section(quota: internalAnswer(#"{ "unlimited": true }"#, plan: "copilot_galaxy"))
        #expect(unknownPlan.plan == "Copilot Galaxy")
    }

    @Test("a token without billing access, or a refused meter endpoint, says so under rows that show dashes")
    func partialFailures() throws {
        let forbidden = #"{ "status": 403, "body": { "message": "Resource not accessible by personal access token" } }"#
        let noPlanPermission = try section(credits: forbidden, billing: forbidden,
                                           quota: internalAnswer(#"{ "entitlement": 300, "remaining": 150 }"#))
        #expect(texts(noPlanPermission) == ["Premium requests 50% · Resets Sat Oct 31 5:00 PM", "This month —"])
        #expect(noPlanPermission.note == "This token can't read billing: give it the Plan permission (read)")

        let refused = try section(quota: #"{ "status": 404, "body": { "message": "Not Found" } }"#)
        #expect(texts(refused) == ["Premium requests —", "This month 0 AI credits"])
        #expect(refused.note?.hasPrefix("GitHub's undocumented Copilot endpoint answered HTTP 404: give the token the Copilot Requests permission (read)") == true)

        let unreachable = try section(quota: #"{ "status": null }"#)
        #expect(texts(unreachable).first == "Premium requests —")
        #expect(unreachable.note?.hasPrefix("Couldn't reach GitHub's undocumented Copilot endpoint") == true)
    }

    @Test("nothing readable is no reading: the rows show dashes and the note says the answer was unreadable")
    func unreadable() throws {
        let json = #"""
        { "now": "2026-10-14T10:00:00-07:00", "timeZone": "America/Los_Angeles", "readings": { "copilot": [
          { "receivedAt": "2026-10-14T09:58:00-07:00", "status": 200, "body": { "renamed": true } } ] } }
        """#
        let fixture = try Fixture.decode(Data(json.utf8))
        let section = try #require(UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)["copilot"])
        #expect(texts(section) == ["This month —"])
        #expect(section.note == "Couldn't read the answer from api.github.com")
    }
}

/// What `CopilotAPI.fetch` asks GitHub, with what, and what it does with the
/// answers.
@MainActor
@Suite("GitHub Copilot requests")
struct CopilotRequestTests {
    let user = PollOutcome.response(status: 200, body: Data(#"{ "login": "mona-example", "id": 1 }"#.utf8))
    let report = PollOutcome.response(status: 200, body: Data(#"{ "timePeriod": { "year": 2026, "month": 11 }, "usageItems": [{ "model": "GPT-5", "grossQuantity": 5, "grossAmount": 0.2, "netAmount": 0 }] }"#.utf8))
    let quota = PollOutcome.response(status: 200, body: Data(#"{ "copilot_plan": "individual", "quota_snapshots": { "premium_interactions": { "entitlement": 300, "remaining": 150 } } }"#.utf8))

    func poller(_ transport: FakeTransport, at time: String = "2026-10-31T18:00:00-07:00", log: @escaping (String) -> Void = { _ in }) -> KeyPoller<CopilotAPI> {
        let clock = date(time)
        return KeyPoller<CopilotAPI>(store: MemoryKeyStore(["copilot": fakeKey]), transport: transport, now: { clock }, log: log)
    }

    @Test("the username comes from GET /user with the same token, then this UTC month's report; every request goes to api.github.com")
    func requests() async throws {
        let transport = FakeTransport(user, report)
        let poller = poller(transport)
        await poller.poll(.timer)
        let urls = transport.requests.map { $0.url?.absoluteString }
        // 6 PM on 31 Oct in Los Angeles is 1 Nov in UTC: November's report.
        #expect(urls == [
            "https://api.github.com/user",
            "https://api.github.com/users/mona-example/settings/billing/ai_credit/usage?year=2026&month=11",
            "https://api.github.com/users/mona-example/settings/billing/premium_request/usage?year=2026&month=11",
        ])
        for request in transport.requests {
            #expect(request.url?.host == "api.github.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
        }
        #expect(poller.provider.problem == nil)
        #expect(poller.provider.reading?.login == "mona-example")
    }

    @Test("with the meter option on, it also asks copilot_internal/user on api.github.com, and only then")
    func meterOption() async throws {
        let transport = FakeTransport(user, report, report, quota)
        let poller = poller(transport)
        poller.setOptions([CopilotAPI.meterOption.id])
        await poller.poll(.timer)
        let last = try #require(transport.requests.last)
        #expect(transport.requests.count == 4)
        #expect(last.url?.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")
        #expect(last.value(forHTTPHeaderField: "Accept") == "application/json")
        let section = try #require(UsageEngine.snapshot(from: Readings([poller.provider]), now: date("2026-10-31T18:00:00-07:00"), timeZone: losAngeles)["copilot"])
        #expect(section.rows.map(\.id) == ["copilot.premium", "copilot.month", "copilot.premiumRequests"])

        // Turned off, the meter goes at once, before any answer, and the
        // next poll leaves copilot_internal out.
        transport.answer(user, report)
        poller.setOptions([])
        let hidden = try #require(UsageEngine.snapshot(from: Readings([poller.provider]), now: date("2026-10-31T18:00:00-07:00"), timeZone: losAngeles)["copilot"])
        #expect(hidden.rows.map(\.id) == ["copilot.month", "copilot.premiumRequests"])
        #expect(poller.isDue(.popover, at: date("2026-10-31T18:00:00-07:00")))
        await poller.poll(.popover)
        #expect(transport.requests.count == 7)
        #expect(transport.requests.last?.url?.path == "/users/mona-example/settings/billing/premium_request/usage")
    }

    @Test("a token that can read neither billing report fails Test connection, though polling shows its other rows")
    func connectionWithoutBilling() async {
        let forbidden = PollOutcome.response(status: 403, body: Data(#"{ "message": "Resource not accessible by personal access token" }"#.utf8))
        let refused = poller(FakeTransport(user, forbidden, forbidden))
        #expect(await refused.testConnection(key: nil) == .failed("This token can't read billing: give it the Plan permission (read)"))
        let readable = poller(FakeTransport(user, report, forbidden))
        #expect(await readable.testConnection(key: nil) == .connected)
    }

    @Test("a 403 that says the rate limit is used up keeps the last reading and backs off, rather than rejecting the token")
    func rateLimited403() async {
        let limited = PollOutcome.response(status: 403, body: Data(#"{ "message": "API rate limit exceeded for user ID 1." }"#.utf8), retryAfter: 1200)
        let transport = FakeTransport(user, report, report, limited)
        let clock = FakeClock(date("2026-10-31T18:00:00-07:00"))
        let poller = KeyPoller<CopilotAPI>(store: MemoryKeyStore(["copilot": fakeKey]), transport: transport, now: { clock.now })
        await poller.poll(.timer)
        let good = poller.provider.reading
        clock.now += 6 * 60
        await poller.poll(.timer)  // /user rate-limited
        #expect(poller.provider.reading == good)
        #expect(poller.provider.problem == nil)
        // Retry-After's 20 minutes.
        #expect(!poller.isDue(.timer, at: clock.now + 19 * 60))

        transport.answer(user, PollOutcome.response(status: 403, body: Data(#"{ "message": "You have exceeded a secondary rate limit." }"#.utf8)))
        clock.now += 61 * 60
        await poller.poll(.timer)  // a report rate-limited
        #expect(poller.provider.reading == good)
    }

    @Test("Test connection needs a report it could read, empty or not")
    func connectionNeedsAReport() async {
        let notFound = PollOutcome.response(status: 404, body: Data(#"{ "message": "Not Found" }"#.utf8))
        let missing = poller(FakeTransport(user, notFound, notFound))
        #expect(await missing.testConnection(key: nil) == .failed("Couldn't read the usage reports from api.github.com"))
        let empty = poller(FakeTransport(user, .response(status: 200, body: Data(#"{ "usageItems": [] }"#.utf8)), notFound))
        #expect(await empty.testConnection(key: nil) == .connected)
    }

    @Test("a token GET /user rejects is \"Key rejected\", and nothing else is asked")
    func rejected() async {
        let transport = FakeTransport(.response(status: 401, body: Data(#"{ "message": "Bad credentials" }"#.utf8)))
        let poller = poller(transport)
        await poller.poll(.timer)
        #expect(transport.requests.count == 1)
        #expect(poller.provider.problem == .rejected)
        #expect(await poller.testConnection(key: nil) == .rejected)
    }

    @Test("a 429 or 5xx on the report keeps the last reading and backs off")
    func transient() async {
        let transport = FakeTransport(user, report, report, user, .response(status: 503, body: Data()))
        let clock = FakeClock(date("2026-10-31T18:00:00-07:00"))
        let poller = KeyPoller<CopilotAPI>(store: MemoryKeyStore(["copilot": fakeKey]), transport: transport, now: { clock.now })
        await poller.poll(.timer)
        let good = poller.provider.reading
        #expect(good != nil)
        clock.now += 6 * 60
        #expect(await poller.poll(.timer))
        #expect(transport.requests.count == 5)
        #expect(poller.provider.reading == good)
        #expect(poller.provider.problem == nil)
        // Backing off: not due again in 5 minutes.
        #expect(!poller.isDue(.timer, at: clock.now + 5 * 60))
    }

    @Test("a username that isn't a GitHub login is never put in a URL")
    func oddLogin() async {
        for login in ["../../evil", "evil.com/x", "a b", "", "mona?x=1"] {
            let body = try! JSONSerialization.data(withJSONObject: ["login": login])
            let transport = FakeTransport(.response(status: 200, body: body), report)
            let poller = poller(transport)
            await poller.poll(.timer)
            #expect(transport.requests.count == 1, "\(login)")
            #expect(poller.provider.problem == .unreadable)
        }
    }

    @Test("the token appears only in Authorization headers: never in a URL, a log line or the reading")
    func tokenStaysPut() async throws {
        var lines: [String] = []
        let transport = FakeTransport(user, report, report, quota)
        let poller = poller(transport, log: { lines.append($0) })
        poller.setOptions([CopilotAPI.meterOption.id])
        await poller.poll(.timer)
        for request in transport.requests {
            #expect(!(request.url?.absoluteString.contains(fakeKey) ?? true))
            let others = (request.allHTTPHeaderFields ?? [:]).filter { $0.key != "Authorization" }
            #expect(!"\(others)".contains(fakeKey))
        }
        #expect(!lines.joined().contains(fakeKey))
        #expect(!"\(String(describing: poller.provider.reading))".contains(fakeKey))
    }

    @Test("Copilot is in the catalog with its meter option, off by default and marked undocumented")
    func catalog() throws {
        let info = try #require(BuiltInProviders.catalog.first { $0.id == "copilot" })
        #expect(info.name == "GitHub Copilot")
        #expect(info.usesKey)
        #expect(info.options.map(\.title) == ["Quota meter and plan"])
        #expect(info.options.first?.detail == "Uses an undocumented GitHub endpoint")
        #expect(CopilotAPI.hosts == ["api.github.com"])
        let item = try #require(ProviderSettings().menuItems(BuiltInProviders.catalog, detected: ["copilot"]).first { $0.id == "copilot" })
        #expect(item.options.map(\.isOn) == [false])
    }
}
