import Foundation
import Testing
import UsageCore

/// app-server is the live Codex source; the session logs stand in when it
/// isn't available, and catch up turns run by other Codex processes (whose
/// pushes our app-server never sees).
@Suite("Codex sources")
struct CodexSourcesTests {
    let plusLog = CodexSessionLog.latestLimits(in: try! Data(contentsOf: fixtureURL("codex/session-log-plus.jsonl")))

    func appServerReading(at time: Date) throws -> CodexLimits? {
        replay(Array(try fixtureLines("codex/app-server.jsonl").prefix(3)), at: time).limits.last
    }

    @Test("with app-server unavailable, Codex shows the latest session-log record")
    func fallback() {
        let section = snapshot(codexSessionLog: plusLog, at: date("2026-10-04T20:24:00-07:00"))
        #expect(section.menuBar.codex.text == "38%")
        #expect(section.codex.meters.map(\.percentText) == ["38%", "6%"])
    }

    @Test("a fresher app-server reading wins over an older session-log record")
    func appServerFresher() throws {
        let appServer = try appServerReading(at: date("2026-10-10T21:57:20-07:00"))
        let section = snapshot(codex: appServer, codexSessionLog: plusLog, at: date("2026-10-10T21:58:00-07:00"))
        #expect(section.codex.plan == "Plus")
        #expect(section.codex.meters.map(\.label) == ["Weekly"])
    }

    @Test("a session-log record newer than the last app-server reading wins")
    func sessionLogFresher() throws {
        let appServer = try appServerReading(at: date("2026-10-04T18:00:00-07:00"))
        let section = snapshot(codex: appServer, codexSessionLog: plusLog, at: date("2026-10-04T20:24:00-07:00"))
        #expect(section.codex.plan == "Plus")
        #expect(section.codex.updatedText == "Updated just now")
        #expect(section.menuBar.codex.text == "38%")
    }

    @Test("with no usable source, the Codex meters and the menu bar number show a dash")
    func noUsableSource() throws {
        let lines = try fixtureLines("codex/app-server.jsonl")
        // A read whose windows have no length can't be placed on any meter.
        let read = String(decoding: lines[2], as: UTF8.self)
            .replacingOccurrences(of: #""windowDurationMins":10080,"#, with: "")
        let appServer = replay([lines[0], Data(read.utf8)], at: now).limits.last
        let log = CodexSessionLog.latestLimits(in: Data("""
        {"timestamp":"2026-10-10T20:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}
        """.utf8))
        #expect(appServer == nil)
        #expect(log == nil)
        let section = snapshot(codex: appServer, codexSessionLog: log)
        #expect(section.menuBar.codex.text == "—")
        #expect(section.codex.meters.map(\.label) == ["Weekly"])
        #expect(section.codex.meters.map(\.percentText) == ["—"])
    }

    @Test("a window whose numbers are missing keeps its meter and shows a dash; extra fields are ignored")
    func missingNumbers() throws {
        let lines = try fixtureLines("codex/app-server.jsonl")
        let read = String(decoding: lines[2], as: UTF8.self)
            .replacingOccurrences(of: #""usedPercent":0,"#, with: #""usedPercentage":0,"somethingNew":[1,2],"#)
        let appServer = replay([lines[0], Data(read.utf8)], at: date("2026-10-10T21:57:20-07:00")).limits.last
        let section = snapshot(codex: appServer, at: date("2026-10-10T21:58:00-07:00"))
        #expect(section.codex.plan == "Plus")
        #expect(section.codex.meters.map(\.label) == ["Weekly"])
        #expect(section.codex.meters.map(\.percentText) == ["—"])
        #expect(section.menuBar.codex.text == "—")
    }
}
