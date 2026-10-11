import Foundation
import Testing
import UsageCore

/// Token-count records from Codex session logs (`~/.codex/sessions/**/*.jsonl`),
/// recorded on this Mac: a "plus" plan with a 5-hour and a weekly window, and
/// a "plus" plan whose only window is weekly.
@Suite("Codex session logs")
struct CodexSessionLogTests {
    @Test("a plan with a 5-hour window gets a 5-hour meter, listed before the weekly one")
    func plusPlan() throws {
        let limits = CodexSessionLog.lastRecord(in: try Data(contentsOf: fixtureURL("codex/session-log-plus.jsonl")))?.limits
        // Recorded Sun 4 Oct 2026, 8:23:41 PM in Los Angeles.
        let section = snapshot(codex: limits, at: date("2026-10-04T20:24:00-07:00"))
        #expect(section.menuBar.codex.text == "38%")
        #expect(section.codex.plan == "Plus")
        #expect(section.codex.updatedText == "Updated just now")
        #expect(section.codex.meters.map(\.label) == ["5-hour session", "Weekly"])
        #expect(section.codex.meters.map(\.percentText) == ["38%", "6%"])
        #expect(section.codex.meters.map(\.resetText) == ["Resets in 4h 13m (12:36 AM)", "Resets Sun 7:36 PM"])
        #expect(section.codex.note == nil)
    }

    @Test("on a plan whose primary slot is the weekly window, it's the weekly meter")
    func primaryIsWeekly() throws {
        let limits = CodexSessionLog.lastRecord(in: try Data(contentsOf: fixtureURL("codex/session-log-weekly.jsonl")))?.limits
        // Recorded Sat 10 Oct 2026, 1:22:28 PM in Los Angeles.
        let section = snapshot(codex: limits, at: date("2026-10-10T13:23:00-07:00"))
        #expect(section.menuBar.codex.text == "0%")
        #expect(section.codex.plan == "Plus")
        #expect(section.codex.updatedText == "Updated just now")
        #expect(section.codex.meters.map(\.label) == ["Weekly"])
        #expect(section.codex.meters.map(\.resetText) == ["Resets Sat 1:16 PM"])
        #expect(section.codex.note == "No 5-hour limit on your plan")
    }

    @Test("the last Codex record in a log wins; lines that aren't Codex rate-limit records are skipped")
    func lastRecordWins() throws {
        let prolite = try Data(contentsOf: fixtureURL("codex/session-log-weekly.jsonl"))
        let noise = Data("""
        ,"partial":"line from reading a tail"}
        {"timestamp":"2026-10-10T20:23:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}
        {"timestamp":"2026-10-10T20:23:01.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_other","primary":{"used_percent":50.0,"window_minutes":300,"resets_at":1791800000}}}}
        {"timestamp":"2026-10-10T20:23:02.000Z","type":"response_item","payload":{"type":"message"}}
        not json

        """.utf8)
        let record = CodexSessionLog.lastRecord(in: prolite + noise)
        #expect(record?.limits?.plan == "plus")
        #expect(record?.capturedAt == date("2026-10-10T20:22:28.809Z"))
    }

    @Test("a later record whose timestamp can't be read still wins; it just has no updated time")
    func unreadableTimestamp() throws {
        let prolite = try Data(contentsOf: fixtureURL("codex/session-log-weekly.jsonl"))
        let later = String(decoding: try fixtureLines("codex/session-log-plus.jsonl").last!, as: UTF8.self)
            .replacingOccurrences(of: #""timestamp":"2026-10-05T03:23:41.086Z""#, with: #""time":"later""#)
        let record = CodexSessionLog.lastRecord(in: prolite + Data((later + "\n").utf8))
        #expect(record?.limits?.plan == "plus")
        #expect(record?.capturedAt == nil)
        #expect(snapshot(codexSessionLog: record?.limits).codex.updatedText == nil)
    }

    @Test("a newest Codex record that can't be read drops the older reading, so the meters show a dash")
    func unreadableNewestRecord() throws {
        let prolite = try Data(contentsOf: fixtureURL("codex/session-log-weekly.jsonl"))
        let renamed = String(decoding: try fixtureLines("codex/session-log-weekly.jsonl").last!, as: UTF8.self)
            .replacingOccurrences(of: "2026-10-10T20:22:28.809Z", with: "2026-10-10T20:30:00.000Z")
            .replacingOccurrences(of: "window_minutes", with: "window_length")
        let record = CodexSessionLog.lastRecord(in: prolite + Data((renamed + "\n").utf8))
        #expect(record != nil)
        #expect(record?.capturedAt == date("2026-10-10T20:30:00.000Z"))
        #expect(record?.limits == nil)
        #expect(snapshot(codexSessionLog: record?.limits).menuBar.codex.text == "—")
    }
}
