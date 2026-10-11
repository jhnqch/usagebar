import Foundation
import Testing
import UsageCore

/// A response from Claude's usage endpoint recorded on this Mac (Max,
/// no ids in it to scrub): `five_hour` and `seven_day` windows, the newer
/// `limits[]` list with Fable as a `weekly_scoped` entry, and many fields
/// UsageBar doesn't use.
@Suite("Claude usage endpoint")
struct ClaudeUsageEndpointTests {
    /// When the response was received: Sat 10 Oct 2026, 11:24:52 PM in Los Angeles.
    let receivedAt = date("2026-10-10T23:24:52-07:00")

    func recorded() throws -> Data {
        try Data(contentsOf: fixtureURL("claude/usage-response.json"))
    }

    @Test("the recorded response shows the 5-hour, weekly and Fable windows")
    func recordedResponse() throws {
        let limits = ClaudeUsageEndpoint.limits(fromResponse: try recorded(), capturedAt: receivedAt)
        let section = snapshot(claude: limits, at: date("2026-10-10T23:25:00-07:00"))
        #expect(section.claude.meters.map(\.label) == ["5-hour session", "Weekly · all models", "Weekly · Fable"])
        #expect(section.claude.meters.map(\.percentText) == ["26%", "12%", "0%"])
        // The endpoint says 08:49:59.820801Z and 06:59:59.820830Z; the status
        // line reports the same windows as 08:50:00Z and 07:00:00Z.
        #expect(section.claude.meters.map(\.resetText) == [
            "Resets in 2h 25m (1:50 AM)",
            "Resets Fri 12:00 AM",
            "Resets Fri 12:00 AM",
        ])
        #expect(section.claude.updatedText == "Updated just now")
        #expect(section.menuBar.claude.text == "26%")
    }

    /// The recorded response with its `limits[]` entries filtered.
    func recorded(keepingLimits keep: @escaping ([String: Any]) -> Bool) throws -> Data {
        editing(try recorded()) { json in
            json["limits"] = (json["limits"] as? [[String: Any]] ?? []).filter(keep)
        }
    }

    @Test("a response with no Fable entry shows a dash for Fable only")
    func missingFable() throws {
        let response = try recorded { $0["kind"] as? String != "weekly_scoped" }
        let section = snapshot(claude: ClaudeUsageEndpoint.limits(fromResponse: response, capturedAt: receivedAt), at: receivedAt)
        #expect(section.claude.meters.map(\.percentText) == ["26%", "12%", "—"])
        #expect(section.claude.meters[2].resetText == nil)
        #expect(section.menuBar.claude.text == "26%")
    }

    @Test("without the flat five_hour and seven_day windows, the session and weekly_all entries stand in")
    func limitsListOnly() throws {
        let response = editing(try recorded()) {
            $0["five_hour"] = nil
            $0["seven_day"] = NSNull()
        }
        let section = snapshot(claude: ClaudeUsageEndpoint.limits(fromResponse: response, capturedAt: receivedAt), at: receivedAt)
        #expect(section.claude.meters.map(\.percentText) == ["26%", "12%", "0%"])
        #expect(section.claude.meters.map(\.resetText) == [
            "Resets in 2h 26m (1:50 AM)",
            "Resets Fri 12:00 AM",
            "Resets Fri 12:00 AM",
        ])
    }

    @Test("Fable from a flat seven_day_fable window when limits[] has no Fable entry")
    func flatFable() throws {
        let response = editing(try recorded { $0["kind"] as? String != "weekly_scoped" }) {
            $0["seven_day_fable"] = ["utilization": 40.0, "resets_at": "2026-10-16T07:00:00+00:00"]
        }
        let section = snapshot(claude: ClaudeUsageEndpoint.limits(fromResponse: response, capturedAt: receivedAt), at: receivedAt)
        #expect(section.claude.meters.map(\.percentText) == ["26%", "12%", "40%"])
        #expect(section.claude.meters[2].resetText == "Resets Fri 12:00 AM")
    }

    @Test("unknown fields are ignored; a Fable entry with a renamed field shows a dash, the rest still show")
    func unknownAndRenamedFields() throws {
        let response = editing(try recorded { $0["kind"] as? String != "weekly_scoped" }) { json in
            json["something_new"] = ["nested": [1, 2, 3]]
            json["five_hour", "burst_factor"] = 1.5
            json["limits"] = (json["limits"] as? [[String: Any]] ?? []) + [
                // A Fable limit that isn't the weekly one.
                ["kind": "monthly_scoped", "group": "monthly", "percent": 88, "resets_at": "2026-11-01T00:00:00+00:00",
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"]]],
                // The weekly Fable entry, with `percent` renamed.
                ["kind": "weekly_scoped", "group": "weekly", "pct": 34, "resets_at": "2026-10-16T07:00:00+00:00",
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"]]],
                ["kind": "brand_new_kind", "percent": "lots"],
                "not an object",
            ]
        }
        let section = snapshot(claude: ClaudeUsageEndpoint.limits(fromResponse: response, capturedAt: receivedAt), at: receivedAt)
        #expect(section.claude.meters.map(\.percentText) == ["26%", "12%", "—"])
        #expect(section.menuBar.claude.text == "26%")
    }

    /// The status line recorded for ticket #4: 5-hour 19% and weekly 11% at
    /// 10:45:53 PM, in the same windows as the recorded response.
    func recordedStatusLine() throws -> ClaudeLimits? {
        let afterReply = try fixtureLines("claude/status-line.jsonl")[1]
        return ClaudeStatusLine.run(input: afterReply, saved: nil, now: date("2026-10-10T22:45:53-07:00"))
            .save.flatMap(ClaudeStatusLine.limits(fromSaved:))
    }

    @Test(
        "a body with nothing readable leaves Fable a dash and the status line's numbers and time",
        arguments: [
            "<html>Bad gateway</html>",
            "[]",
            "{}",
            #"{"type":"error","error":{"type":"authentication_error","message":"x-api-key header is required"}}"#,
        ]
    )
    func unreadableBody(body: String) throws {
        let limits = ClaudeUsageEndpoint.limits(fromResponse: Data(body.utf8), capturedAt: receivedAt)
        let section = snapshot(claude: limits, claudeStatusLine: try recordedStatusLine(), at: date("2026-10-10T23:25:00-07:00"))
        #expect(section.claude.meters.map(\.percentText) == ["19%", "11%", "—"])
        #expect(section.claude.updatedText == "Updated 39 min ago")
        #expect(section.menuBar.claude.text == "19%")
    }

    // MARK: - The request

    /// A made-up Keychain secret in Claude Code's shape.
    let secret = Data("""
    {"claudeAiOauth":{"accessToken":"fake-access","refreshToken":"fake-refresh","expiresAt":1791700000000,"scopes":["user:inference"],"subscriptionType":"max"}}

    """.utf8)

    @Test("the access token is claudeAiOauth.accessToken in the Keychain secret, and nothing else")
    func accessToken() {
        #expect(ClaudeUsageEndpoint.accessToken(fromSecret: secret) == "fake-access")
    }

    @Test(
        "a secret without a usable access token gives none",
        arguments: [
            "",
            "not json",
            #"{"claudeAiOauth":{"refreshToken":"fake-refresh"}}"#,
            #"{"claudeAiOauth":{"accessToken":""}}"#,
            #"{"claudeAiOauth":{"accessToken":42}}"#,
            #"{"accessToken":"fake-access"}"#,
        ]
    )
    func noAccessToken(secret: String) {
        #expect(ClaudeUsageEndpoint.accessToken(fromSecret: Data(secret.utf8)) == nil)
    }

    @Test("the request is a GET to api.anthropic.com with the token, the beta header, and no caching")
    func request() throws {
        let request = ClaudeUsageEndpoint.request(accessToken: "fake-access", userAgent: "UsageBar/0.1.0")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UsageBar/0.1.0")
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.httpBody == nil)
    }
}
