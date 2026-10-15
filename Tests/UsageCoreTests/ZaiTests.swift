import Foundation
import Testing
import UsageCore

/// The z.ai GLM Coding Plan's undocumented `GET /api/monitor/usage/quota/limit`
/// answers, from synthetic fixtures built on the shape z.ai's own ZCode docs
/// describe, through the engine to what the popover and menu bar show.
@Suite("z.ai")
struct ZaiTests {
    func snapshot(_ name: String) throws -> UsageSnapshot {
        let fixture = try loadFixture(name)
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone, selection: fixture.selection)
    }

    func meters(_ section: ProviderSection) -> [Meter] {
        section.rows.compactMap { row in
            if case let .meter(meter) = row { meter } else { nil }
        }
    }

    /// "label percent · reset" per row.
    func texts(_ section: ProviderSection) -> [String] {
        section.rows.map { row in
            switch row {
            case let .meter(meter): "\(meter.label) \(meter.percentText)\(meter.resetText.map { " · \($0)" } ?? "")"
            case let .credit(credit): "\(credit.label) \(credit.valueText)"
            case let .value(value): "\(value.label) \(value.valueText)"
            }
        }
    }

    @Test("the 5-hour, weekly and MCP limits are meters with resets, pace and predictions, under the plan badge")
    func quota() throws {
        let snapshot = try snapshot("zai-quota")
        #expect(snapshot.sections.map(\.name) == ["z.ai"])
        let section = try #require(snapshot["zai"])
        #expect(section.plan == "Pro")
        #expect(section.updatedText == "Updated 2 min ago")
        #expect(texts(section) == [
            "5-hour 72% · Resets in 2h 18m (4:58 PM)",
            "Weekly 41% · Resets Tue 7:00 AM",
            // 3:15 AM UTC on Mon 2 Nov is after daylight saving ends in Los
            // Angeles on Sun 1 Nov: 7:15 PM PST. Beyond a week, the date
            // tells it from tomorrow.
            "MCP tools 22% · Resets Sun Nov 1 7:15 PM",
        ])
        let meters = meters(section)
        #expect(meters.map(\.elapsedText) == ["54% of window elapsed", "62% of window elapsed", "28% of window elapsed"])
        #expect(meters.map { $0.prediction?.text } == [
            "Ahead of pace: limit around 3:45 PM",
            "Below pace: about 66% by reset",
            "Below pace: about 79% by reset",
        ])
        #expect(meters[2].usageText == "224 of 1,000 calls used")
        #expect(section.note == nil)
        #expect(snapshot.menuBar.text == "ℤ 72%")
    }

    /// Answers for `id` received two minutes before the test clock, in Los
    /// Angeles unless `timeZone` and `now` say otherwise.
    func snapshot(
        _ id: String = "zai", polls: [(status: Int, body: String)], now: String = "2026-10-10T14:40:00-07:00",
        receivedAt: String = "2026-10-10T14:38:00-07:00", timeZone: String = "America/Los_Angeles", memory: AlertMemory = AlertMemory()
    ) throws -> UsageSnapshot {
        let answers = polls.map { #"{ "receivedAt": "\#(receivedAt)", "status": \#($0.status), "body": \#($0.body) }"# }
        let json = #"{ "now": "\#(now)", "timeZone": "\#(timeZone)", "readings": { "\#(id)": [\#(answers.joined(separator: ","))] } }"#
        let fixture = try Fixture.decode(Data(json.utf8))
        return UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone, alertMemory: memory)
    }

    func section(_ id: String = "zai", limits: String, extra: String = "", now: String = "2026-10-10T14:40:00-07:00",
                 receivedAt: String = "2026-10-10T14:38:00-07:00", timeZone: String = "America/Los_Angeles") throws -> ProviderSection {
        let body = #"{ "code": 200, "success": true, "data": { "limits": \#(limits)\#(extra) } }"#
        return try #require(try snapshot(id, polls: [(200, body)], now: now, receivedAt: receivedAt, timeZone: timeZone)[id])
    }

    @Test("a key rejected in a 200's body drops the reading: the rows show dashes and the note says so")
    func rejected() throws {
        let section = try #require(try snapshot("zai-rejected")["zai"])
        #expect(texts(section) == ["5-hour —", "Weekly —"])
        #expect(section.note == "Key rejected")
        #expect(section.updatedText == nil)
        #expect(section.plan == nil)
    }

    @Test("an account without a Coding Plan says so under dashes")
    func noPlan() throws {
        let section = try #require(try snapshot(polls: [(200, #"{ "code": 500, "msg": "当前用户不存在coding plan", "success": false }"#)])["zai"])
        #expect(texts(section) == ["5-hour —", "Weekly —"])
        #expect(section.note == "No GLM Coding Plan on this key")
    }

    @Test("a server error in a 200's body keeps the last reading, as a 5xx would")
    func serverErrorInBody() throws {
        let good = #"{ "code": 200, "success": true, "data": { "limits": [{ "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 40, "nextResetTime": 1791676680000 }] } }"#
        let section = try #require(try snapshot(polls: [(200, good), (200, #"{ "code": 500, "msg": "system busy", "success": false }"#)])["zai"])
        #expect(texts(section) == ["5-hour 40% · Resets in 2h 18m (4:58 PM)"])
        #expect(section.note == nil)
    }

    @Test("an empty or changed answer degrades to dashes with a note, not a crash")
    func emptyOrChanged() throws {
        let empty = try section(limits: "[]")
        #expect(texts(empty) == ["5-hour —", "Weekly —"])
        #expect(empty.note == "The answer from api.z.ai had no quota limits")

        for body in [#"{ "code": 200, "success": true, "data": {} }"#, #"{ "code": 200, "success": true, "data": { "limits": {} } }"#,
                     #"{ "code": 200, "success": true, "data": [] }"#, #"[]"#, #""not json""#, #"{ "code": 1001, "msg": "?", "success": false }"#] {
            let section = try #require(try snapshot(polls: [(200, body)])["zai"])
            #expect(texts(section) == ["5-hour —", "Weekly —"], "\(body)")
            #expect(section.note == "Couldn't read the answer from api.z.ai", "\(body)")
        }

        let junk = try section(limits: "[7, null, \"x\", {}]")
        #expect(texts(junk) == ["5-hour —", "Weekly —"])
        #expect(junk.note == "Couldn't read the quota limits from api.z.ai")
    }

    @Test("an unreadable entry beside good ones leaves those, with a note")
    func partlyUnreadable() throws {
        let section = try section(limits: #"[7, { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": "61", "nextResetTime": 1791676680000, "new": 1 }]"#)
        #expect(texts(section) == ["5-hour 61% · Resets in 2h 18m (4:58 PM)"])
        #expect(section.note == "Some quota limits couldn't be read")
    }

    @Test("without a unit the window's length comes from the type and how far off the reset is")
    func inferredLength() throws {
        let section = try section(limits: #"""
            [{ "type": "TIME_LIMIT", "percentage": 5, "nextResetTime": 1794182400000 },
             { "type": "TOKENS_LIMIT", "percentage": 30, "nextResetTime": 1791856800000 },
             { "type": "TOKENS_LIMIT", "unit": 99, "number": 5, "percentage": 50, "nextResetTime": 1791671400000 },
             { "type": "TOKENS_LIMIT", "unit": 3, "number": "lots", "percentage": 9, "nextResetTime": 1794182400000 }]
            """#)
        // Windows are named by kind and place in the answer, not by length,
        // which can be guessed differently from poll to poll.
        #expect(section.rows.map(\.id) == ["zai.tokens.1", "zai.tokens.0", "zai.tokens.2", "zai.mcp.0"])
        #expect(texts(section) == [
            "5-hour 50% · Resets in 50m (3:30 PM)",
            "Weekly 30% · Resets Mon 7:00 PM",
            "Monthly 9% · Resets Sun Nov 8 4:00 PM",
            "MCP tools 5% · Resets Sun Nov 8 4:00 PM",
        ])
        // The 5-hour window started 4h10m ago; the weekly one 4d19h40m ago.
        #expect(meters(section).prefix(2).map(\.elapsedText) == ["83% of window elapsed", "69% of window elapsed"])
    }

    @Test("an entry of an unknown type, or with counts but no percent, still gets a meter; days and multiples get their own labels")
    func unknownEntries() throws {
        let section = try section(limits: #"""
            [{ "type": "SOMETHING_NEW", "unit": 6, "number": 1, "percentage": 12, "nextResetTime": 1791856800000 },
             { "unit": 1, "number": 1, "usage": 200, "remaining": 50, "nextResetTime": 1791705600000 },
             { "type": "CREDIT_LIMIT", "unit": 3, "number": 2, "usage": 2000, "currentValue": 500, "percentage": 1, "nextResetTime": 1791671400000 },
             { "type": "TIME_LIMIT", "unit": 6, "number": 2, "percentage": 3, "nextResetTime": 1791856800000 }]
            """#)
        #expect(texts(section) == [
            "2-hour 25% · Resets in 50m (3:30 PM)",
            "MCP tools · 2-week 3% · Resets Mon 7:00 PM",
            "Weekly quota 12% · Resets Mon 7:00 PM",
            "Daily quota 75% · Resets in 10h 20m (1:00 AM)",
        ])
        #expect(meters(section)[0].usageText == "500 of 2,000 used")
        #expect(section.rows.map(\.id) == ["zai.tokens.0", "zai.mcp.0", "zai.something_new.0", "zai.unknown.0"])
    }

    @Test("a reset further off than the window is long is hidden: the meter keeps its percent, without pace")
    func implausibleReset() throws {
        let section = try section(limits: #"""
            [{ "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 93, "nextResetTime": 1791705600000 },
             { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 41 }]
            """#)
        #expect(texts(section) == ["5-hour 93%", "Weekly 41%"])
        #expect(meters(section).map(\.level) == [.warning, .normal])
        #expect(meters(section).map(\.prediction) == [nil, nil])
        #expect(section.note == "A reset time from api.z.ai looked wrong, so it's hidden")
    }

    /// Epoch milliseconds are absolute: the same answer reads in each zone's
    /// local time, and London's clocks go back on Sun 25 Oct between the
    /// answer and the weekly reset.
    @Test("epoch-millisecond resets read correctly in two time zones, across a DST change")
    func timeZones() throws {
        let limits = #"""
            [{ "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 20, "nextResetTime": 1792841400000 },
             { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 40, "nextResetTime": 1793091600000 }]
            """#
        let london = try section(limits: limits, now: "2026-10-24T10:00:00+01:00", receivedAt: "2026-10-24T09:59:00+01:00",
                                 timeZone: "Europe/London")
        #expect(texts(london) == ["5-hour 20% · Resets in 2h 30m (12:30 PM)", "Weekly 40% · Resets Tue 9:00 AM"])
        let losAngeles = try section(limits: limits, now: "2026-10-24T02:00:00-07:00", receivedAt: "2026-10-24T01:59:00-07:00")
        #expect(texts(losAngeles) == ["5-hour 20% · Resets in 2h 30m (4:30 AM)", "Weekly 40% · Resets Tue 2:00 AM"])
        // Four of the week's seven days have passed in absolute time, and
        // the prediction lands at the same instant in both zones.
        for section in [london, losAngeles] {
            #expect(meters(section).map(\.elapsedText) == ["50% of window elapsed", "57% of window elapsed"])
        }
        #expect(meters(london)[1].prediction?.text == "Below pace: about 70% by reset")
    }

    @Test("a window at 90% alerts like Claude's, and the MCP quota stays out of the menu bar")
    func alerts() throws {
        let body = #"""
            { "code": 200, "success": true, "data": { "level": "max", "limits": [
              { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 92, "nextResetTime": 1791676680000 },
              { "type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 99, "nextResetTime": 1793589300000 }] } }
            """#
        let snapshot = try snapshot(polls: [(200, body)])
        #expect(snapshot.alerts.map(\.title) == ["z.ai 5-hour quota at 92%", "z.ai MCP tools quota at 99%"])
        #expect(snapshot.menuBar.parts.first { $0.id == "zai" }?.value.text == "92%")
        #expect(snapshot["zai"]?.plan == "Max")
    }

    @Test("BigModel is its own provider on open.bigmodel.cn")
    func bigModel() throws {
        let section = try section("bigmodel", limits: #"[{ "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10, "nextResetTime": 1791676680000 }]"#)
        #expect(section.name == "BigModel")
        #expect(section.rows.map(\.id) == ["bigmodel.tokens.0"])
        #expect(ZaiAPI.hosts == ["api.z.ai"])
        #expect(BigModelAPI.hosts == ["open.bigmodel.cn"])
        let keyed = BuiltInProviders.catalog.filter(\.usesKey).map(\.name)
        #expect(keyed == ["OpenRouter", "DeepSeek", "Moonshot", "Moonshot China", "z.ai", "BigModel"])
    }

    @Test("the key goes in the Authorization header as it is, without Bearer, to api.z.ai only")
    @MainActor
    func authorization() async throws {
        let transport = FakeTransport(.response(status: 200, body: Data(#"{ "code": 401, "msg": "token expired or incorrect", "success": false }"#.utf8)))
        let poller = KeyPoller<ZaiAPI>(store: MemoryKeyStore(["zai": fakeKey]), transport: transport)
        #expect(await poller.testConnection(key: nil) == .rejected)
        await poller.poll(.timer)
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(request.value(forHTTPHeaderField: "Authorization") == fakeKey)
        #expect(poller.provider.problem == .rejected)
    }

    @Test("with no Claude or Codex, a provider with limit windows is the menu bar's default")
    func menuBarDefault() {
        let selection = ProviderSettings().selection(BuiltInProviders.catalog, detected: ["openrouter", "zai"])
        #expect(selection.menuBar == ["zai"])
    }

    /// Rebased to an hour later, everything sits where it sat; at the same
    /// readings an hour on, the 5-hour window has reset.
    @Test("a rebased fixture keeps each window's length and reset; a passed reset reads 0% and drops its counts")
    func rebased() throws {
        let fixture = try loadFixture("zai-quota")
        let later = fixture.now + 3600
        let moved = try #require(UsageEngine.snapshot(from: fixture.readings(rebasedTo: later), now: later, timeZone: fixture.timeZone)["zai"])
        #expect(meters(moved).map(\.elapsedText) == ["54% of window elapsed", "62% of window elapsed", "28% of window elapsed"])
        #expect(meters(moved)[2].usageText == "224 of 1,000 calls used")

        let afterReset = fixture.now + 3 * 86400
        let stale = try #require(UsageEngine.snapshot(from: fixture.readings, now: afterReset, timeZone: fixture.timeZone)["zai"])
        #expect(texts(stale) == ["5-hour 0% · Reset Sat 4:58 PM", "Weekly 0% · Reset at 7:00 AM", "MCP tools 22% · Resets Sun Nov 1 7:15 PM"])
    }

    /// Without a unit, a weekly window with six hours left looks like a
    /// weekly one, and with four hours left like a 5-hour one: it must stay
    /// the same window to alert memory.
    @Test("a window whose length is inferred keeps its identity as its reset nears, so it alerts once")
    func inferredIdentity() throws {
        let body = #"{ "code": 200, "success": true, "data": { "limits": [{ "type": "TOKENS_LIMIT", "percentage": 95, "nextResetTime": 1791690000000 }] } }"#
        let first = try snapshot(polls: [(200, body)])
        #expect(first.alerts.map(\.title).count == 1)
        let second = try snapshot(polls: [(200, body)], now: "2026-10-10T16:40:00-07:00", receivedAt: "2026-10-10T16:38:00-07:00",
                                  memory: first.alertMemory)
        #expect(second["zai"]?.rows.map(\.id) == first["zai"]?.rows.map(\.id))
        #expect(second.alerts == [])
    }

    @Test("huge or fractional unit, number and reset values are ignored, never a crash")
    func outOfRange() throws {
        let section = try section(limits: #"""
            [{ "type": "TOKENS_LIMIT", "unit": 3, "number": 1e20, "percentage": 50, "nextResetTime": 1791671400000 },
             { "type": "TOKENS_LIMIT", "unit": 6, "number": 9223372036854775807, "percentage": 10, "nextResetTime": 1e300 },
             { "type": "TOKENS_LIMIT", "unit": 1e300, "number": 1.5, "percentage": 20, "nextResetTime": -1e300 }]
            """#)
        #expect(texts(section) == ["5-hour 50% · Resets in 50m (3:30 PM)", "Quota 10%", "Quota 20%"])
    }

    @Test("a window keeps its identity when its unit and number go missing, so it alerts once")
    func identityWithoutUnit() throws {
        let explicit = #"{ "code": 200, "success": true, "data": { "limits": [{ "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 95, "nextResetTime": 1791676680000 }] } }"#
        let bare = #"{ "code": 200, "success": true, "data": { "limits": [{ "type": "TOKENS_LIMIT", "percentage": 95, "nextResetTime": 1791676680000 }] } }"#
        let first = try snapshot(polls: [(200, explicit)])
        #expect(first.alerts.count == 1)
        let second = try snapshot(polls: [(200, bare)], now: "2026-10-10T14:50:00-07:00", receivedAt: "2026-10-10T14:48:00-07:00",
                                  memory: first.alertMemory)
        #expect(second["zai"]?.rows.map(\.id) == first["zai"]?.rows.map(\.id))
        #expect(second.alerts == [])
    }
}
