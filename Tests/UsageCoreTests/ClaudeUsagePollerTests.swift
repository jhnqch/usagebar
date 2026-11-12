import Foundation
import Testing
import UsageCore

/// A stand-in for Claude Code's Keychain item and the usage endpoint. The
/// tokens are obviously fake; nothing here touches the real Keychain.
@MainActor
private final class FakeClaude {
    /// What the Keychain holds now; tests change it to rotate the token.
    var login: ClaudeLogin? = ClaudeLogin(token: "fake-token-1", plan: "max")
    /// The status each token gets from the endpoint; 200 by default.
    var statuses: [String: Int] = [:]
    private(set) var keychainReads = 0
    private(set) var sentTokens: [String] = []
    let body: Data

    init() throws {
        body = try Data(contentsOf: fixtureURL("claude/usage-response.json"))
    }

    func poller(now: @escaping () -> Date, log: @escaping (String) -> Void = { _ in }) -> ClaudeUsagePoller {
        ClaudeUsagePoller(
            readLogin: { [unowned self] in
                keychainReads += 1
                return login
            },
            fetch: { [unowned self] token in
                sentTokens.append(token)
                let status = statuses[token] ?? 200
                return .response(status: status, body: status == 200 ? body : Data())
            },
            now: now,
            log: log
        )
    }
}

@Suite("Claude usage poller")
@MainActor
struct ClaudeUsagePollerTests {
    /// Sat 10 Oct 2026, 11:24:52 PM in Los Angeles: when the response was recorded.
    let start = date("2026-10-10T23:24:52-07:00")

    @Test("the first poll reads the login once and keeps the token for the next poll")
    func cachesToken() async throws {
        let claude = try FakeClaude()
        var time = start
        let poller = claude.poller(now: { time })
        #expect(await poller.poll(.timer))
        time += PollSchedule.interval
        #expect(await poller.poll(.timer))
        #expect(claude.keychainReads == 1)
        #expect(claude.sentTokens == ["fake-token-1", "fake-token-1"])
        #expect(poller.reading != nil)
        #expect(poller.plan == "max")
    }

    @Test("a 401 for a cached token, with a newer token in the Keychain, retries once at once with the newer token")
    func rotatedToken() async throws {
        let claude = try FakeClaude()
        var time = start
        var lines: [String] = []
        let poller = claude.poller(now: { time }, log: { lines.append($0) })
        await poller.poll(.timer)
        // Claude Code rotated its token: the old one is refused.
        claude.statuses["fake-token-1"] = 401
        claude.login = ClaudeLogin(token: "fake-token-2", plan: "max")
        time += PollSchedule.interval
        #expect(await poller.poll(.timer))
        #expect(claude.sentTokens == ["fake-token-1", "fake-token-1", "fake-token-2"])
        #expect(claude.keychainReads == 2)
        #expect(poller.reading != nil)
        // The newer token is kept for the next poll.
        time += PollSchedule.interval
        await poller.poll(.timer)
        #expect(claude.sentTokens.last == "fake-token-2")
        #expect(claude.keychainReads == 2)
        // Log lines never hold a token.
        #expect(!lines.contains { $0.contains("fake-token") })
    }

    @Test("a 401 for a cached token with the same token in the Keychain drops the reading without a retry")
    func sameToken() async throws {
        let claude = try FakeClaude()
        var time = start
        let poller = claude.poller(now: { time })
        await poller.poll(.timer)
        claude.statuses["fake-token-1"] = 401
        time += PollSchedule.interval
        await poller.poll(.timer)
        #expect(claude.sentTokens == ["fake-token-1", "fake-token-1"])
        #expect(poller.reading == nil)
        // As before: the next poll reads the Keychain again.
        let reads = claude.keychainReads
        time += PollSchedule.interval
        await poller.poll(.timer)
        #expect(claude.keychainReads == reads + 1)
    }

    @Test("a 401 for a token just read from the Keychain doesn't read it again in the same poll")
    func freshTokenRefused() async throws {
        let claude = try FakeClaude()
        claude.statuses["fake-token-1"] = 401
        let poller = claude.poller(now: { start })
        await poller.poll(.timer)
        #expect(claude.keychainReads == 1)
        #expect(claude.sentTokens == ["fake-token-1"])
        #expect(poller.reading == nil)
    }

    @Test("when the newer token is refused too, there's only the one retry")
    func retryRefused() async throws {
        let claude = try FakeClaude()
        var time = start
        let poller = claude.poller(now: { time })
        await poller.poll(.timer)
        claude.statuses = ["fake-token-1": 401, "fake-token-2": 401]
        claude.login = ClaudeLogin(token: "fake-token-2", plan: "max")
        time += PollSchedule.interval
        await poller.poll(.timer)
        #expect(claude.sentTokens == ["fake-token-1", "fake-token-1", "fake-token-2"])
        #expect(poller.reading == nil)
    }

    @Test("a 401 with no login left in the Keychain drops the reading and the plan")
    func loginGone() async throws {
        let claude = try FakeClaude()
        var time = start
        let poller = claude.poller(now: { time })
        await poller.poll(.timer)
        claude.statuses["fake-token-1"] = 401
        claude.login = nil
        time += PollSchedule.interval
        await poller.poll(.timer)
        #expect(claude.sentTokens == ["fake-token-1", "fake-token-1"])
        #expect(poller.reading == nil)
        #expect(poller.plan == nil)
    }

    @Test("a 401 for a cached token with no login left backs off like no login, so a denied Keychain prompt doesn't come straight back")
    func loginGoneBacksOff() async throws {
        let claude = try FakeClaude()
        var time = start
        let poller = claude.poller(now: { time })
        await poller.poll(.timer)
        claude.statuses["fake-token-1"] = 401
        claude.login = nil
        time += PollSchedule.interval
        await poller.poll(.timer)
        let reads = claude.keychainReads
        time += 2 * PollSchedule.minimumGap
        #expect(await poller.poll(.popover) == false)
        #expect(claude.keychainReads == reads)
    }

    @Test("a poll that isn't due asks nothing")
    func notDue() async throws {
        let claude = try FakeClaude()
        let poller = claude.poller(now: { start })
        await poller.poll(.timer)
        #expect(await poller.poll(.popover) == false)
        #expect(claude.sentTokens.count == 1)
    }

    @Test("stopping forgets the token: the next poll reads the Keychain again")
    func stopForgetsToken() async throws {
        let claude = try FakeClaude()
        var time = start
        let poller = claude.poller(now: { time })
        await poller.poll(.timer)
        poller.stop()
        time += PollSchedule.interval
        #expect(await poller.poll(.timer))
        #expect(claude.keychainReads == 2)
    }
}
