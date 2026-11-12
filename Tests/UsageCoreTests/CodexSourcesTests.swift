import Foundation
import Testing
import UsageCore

/// app-server is the live Codex source; the session logs stand in when it
/// isn't available, and catch up turns run by other Codex processes (whose
/// pushes our app-server never sees).
@Suite("Codex sources")
struct CodexSourcesTests {
    let plusLog = CodexSessionLog.lastRecord(in: try! Data(contentsOf: fixtureURL("codex/session-log-plus.jsonl")))?.limits

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
        let log = CodexSessionLog.lastRecord(in: Data("""
        {"timestamp":"2026-10-10T20:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}
        """.utf8))?.limits
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
    // MARK: Merging per window

    let weekResets = date("2026-10-15T13:16:00-07:00")
    let fiveHourResets = date("2026-10-10T17:00:00-07:00")

    func limits(plan: String?, at time: Date, fiveHour: Double?, weekly: Double?) -> CodexLimits {
        CodexLimits(plan: plan, capturedAt: time, windows: [
            CodexWindow(windowMinutes: 300, reading: fiveHour.map { LimitReading(usedPercent: $0, resetsAt: fiveHourResets) }),
            CodexWindow(windowMinutes: 10080, reading: weekly.map { LimitReading(usedPercent: $0, resetsAt: weekResets) }),
        ])
    }

    @Test("a newer session-log record with one unreadable window keeps app-server's value for that window, and the plan")
    func mergesPerWindow() {
        let appServer = limits(plan: "pro", at: now - 120, fiveHour: 20, weekly: 40)
        let log = limits(plan: nil, at: now - 10, fiveHour: nil, weekly: 45)
        let section = snapshot(codex: appServer, codexSessionLog: log)
        #expect(section.codex.meters.map(\.label) == ["5-hour session", "Weekly"])
        #expect(section.codex.meters.map(\.percentText) == ["20%", "45%"])
        #expect(section.codex.plan == "Pro")
    }

    @Test("a newer app-server reading with one unreadable window keeps the session log's value for it")
    func mergesPerWindowTheOtherWay() {
        let appServer = limits(plan: nil, at: now - 10, fiveHour: 25, weekly: nil)
        let log = limits(plan: "plus", at: now - 120, fiveHour: 20, weekly: 40)
        let section = snapshot(codex: appServer, codexSessionLog: log)
        #expect(section.codex.meters.map(\.percentText) == ["25%", "40%"])
        #expect(section.codex.plan == "Plus")
    }

    @Test("with both readable, the fresher source wins each window and the plan")
    func fresherWinsEachWindow() {
        let appServer = limits(plan: "plus", at: now - 120, fiveHour: 20, weekly: 40)
        let log = limits(plan: "pro", at: now - 10, fiveHour: 22, weekly: 41)
        let section = snapshot(codex: appServer, codexSessionLog: log)
        #expect(section.codex.meters.map(\.percentText) == ["22%", "41%"])
        #expect(section.codex.plan == "Pro")
        #expect(section.codex.updatedText == "Updated just now")
    }

    @Test("the fresher source says which windows there are: one only the older source reports is dropped")
    func fresherSetsWindows() {
        let appServer = CodexLimits(plan: "pro", capturedAt: now - 120, windows: [
            CodexWindow(windowMinutes: 300, reading: LimitReading(usedPercent: 20, resetsAt: fiveHourResets)),
            CodexWindow(windowMinutes: 10080, reading: LimitReading(usedPercent: 40, resetsAt: weekResets)),
        ])
        let log = CodexLimits(plan: "pro", capturedAt: now - 10, windows: [
            CodexWindow(windowMinutes: 10080, reading: LimitReading(usedPercent: 45, resetsAt: weekResets)),
        ])
        let section = snapshot(codex: appServer, codexSessionLog: log)
        #expect(section.codex.meters.map(\.label) == ["Weekly"])
        #expect(section.codex.meters.map(\.percentText) == ["45%"])
    }

    @Test("a fresher source with no windows at all leaves the other source's windows")
    func fresherWithoutWindows() {
        let appServer = limits(plan: "pro", at: now - 120, fiveHour: 20, weekly: 40)
        let log = CodexLimits(plan: nil, capturedAt: now - 10, windows: [])
        let section = snapshot(codex: appServer, codexSessionLog: log)
        #expect(section.codex.meters.map(\.percentText) == ["20%", "40%"])
        #expect(section.codex.plan == "Pro")
    }

    @Test("a window neither source can read shows a dash")
    func windowNeitherReads() {
        let appServer = limits(plan: "pro", at: now - 120, fiveHour: nil, weekly: 40)
        let log = limits(plan: "pro", at: now - 10, fiveHour: nil, weekly: 45)
        #expect(snapshot(codex: appServer, codexSessionLog: log).codex.meters.map(\.percentText) == ["—", "45%"])
    }
}
