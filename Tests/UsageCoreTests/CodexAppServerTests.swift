import Foundation
import Testing
import UsageCore

/// Recorded with codex-cli 0.162.0-alpha.17.2 on a "plus" plan, whose only
/// window is weekly and arrives in the `primary` slot.
@Suite("Codex app-server")
struct CodexAppServerTests {
    /// When the recorded read arrived: Sat 10 Oct 2026, 9:57 PM in Los Angeles.
    let received = date("2026-10-10T21:57:20-07:00")
    let later = date("2026-10-10T21:58:00-07:00")

    @Test("the recorded read gives Codex a weekly meter, identified by the window's length")
    func recordedRead() throws {
        let lines = try fixtureLines("codex/app-server.jsonl")
        let limits = replay(Array(lines.prefix(3)), at: received).limits.last
        let section = snapshot(codex: limits, at: later)
        #expect(section.menuBar.codex.text == "0%")
        #expect(section.codex.meters.map(\.label) == ["Weekly"])
        #expect(section.codex.meters.map(\.percentText) == ["0%"])
        #expect(section.codex.meters.map(\.resetText) == ["Resets Sat 9:33 PM"])
        #expect(section.codex.updatedText == "Updated just now")
        #expect(section.codex.note == "No 5-hour limit on your plan")
    }

    @Test(
        "Codex plan ids read as plan names",
        arguments: [("prolite", "Pro Lite"), ("promax", "Pro Max"), ("plus", "Plus"), ("pro", "Pro")]
    )
    func planBadge(planType: String, badge: String) {
        let limits = CodexLimits(plan: planType, capturedAt: now, windows: codex().windows)
        #expect(snapshot(codex: limits).codex.plan == badge)
    }

    @Test("a rate-limit push updates the meter; other notifications don't")
    func push() throws {
        var lines = try fixtureLines("codex/app-server.jsonl")
        // The recorded push repeated 0%. The same push after some work:
        let push = String(decoding: lines.removeLast(), as: UTF8.self)
            .replacingOccurrences(of: #""usedPercent":0"#, with: #""usedPercent":7"#)
        lines.append(Data(push.utf8))
        let replayed = replay(lines, at: received)
        #expect(replayed.limits.count == 2)
        #expect(snapshot(codex: replayed.limits.last, at: later).menuBar.codex.text == "7%")
    }

    @Test("a push for another limit bucket leaves the Codex meters alone")
    func otherBucket() throws {
        let push = String(decoding: try fixtureLines("codex/app-server.jsonl").last!, as: UTF8.self)
            .replacingOccurrences(of: #""limitId":"codex""#, with: #""limitId":"codex_other""#)
        #expect(replay([Data(push.utf8)], at: received).limits.isEmpty)
    }

    @Test("it sends only initialize, initialized and reads, and declines a token refresh request")
    func neverRefreshesTokens() throws {
        var lines = try fixtureLines("codex/app-server.jsonl")
        let refresh = #"{"id":"srv-1","method":"account/chatgptAuthTokens/refresh","params":{"reason":"unauthorized","previousAccountId":null}}"#
        lines.insert(Data(refresh.utf8), at: 3)
        let replayed = replay(lines, at: received)
        #expect(replayed.sentMethods == ["initialize", "initialized", "account/rateLimits/read", "reply"])
        let replyLine = try #require(replayed.sent.dropFirst(3).first)
        let reply = try #require(try JSONSerialization.jsonObject(with: replyLine) as? [String: Any])
        #expect(reply["id"] as? String == "srv-1")
        #expect(reply["result"] == nil)
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test("reads wait for the handshake")
    func readsWaitForHandshake() throws {
        var conversation = CodexAppServerConversation()
        _ = conversation.start()
        #expect(conversation.requestRateLimits().isEmpty)
        _ = conversation.receive(try fixtureLines("codex/app-server.jsonl")[0], at: received)
        #expect(conversation.requestRateLimits().count == 1)
    }

    @Test("a read that fails is reported and gives no reading")
    func readFails() throws {
        let lines = try fixtureLines("codex/app-server.jsonl")
        let failure = #"{"id":2,"error":{"code":-32600,"message":"not logged in"}}"#
        let replayed = replay([lines[0], Data(failure.utf8)], at: received)
        #expect(replayed.limits.isEmpty)
        #expect(replayed.failures == ["account/rateLimits/read failed: not logged in"])
    }
}

@Suite("app-server restarts")
struct RestartBackoffTests {
    @Test("restart delays double from 1 second up to 5 minutes")
    func doubling() {
        var backoff = RestartBackoff()
        let delays = (0..<11).map { _ in backoff.nextDelay() }
        #expect(delays == [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300].map { Duration.seconds($0) })
    }

    @Test("after a healthy reading, the next restart is quick again")
    func resetsAfterSuccess() {
        var backoff = RestartBackoff()
        _ = (0..<5).map { _ in backoff.nextDelay() }
        backoff.reset()
        #expect(backoff.nextDelay() == .seconds(1))
    }
}
