import Foundation
import UsageCore

/// Loads a fixture from the repo's `Fixtures/` directory.
func loadFixture(_ name: String) throws -> Fixture {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // UsageCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appending(path: "Fixtures/\(name).json")
    return try Fixture.decode(Data(contentsOf: url))
}

/// Sat 10 Oct 2026, 2:40 PM in Los Angeles: the clock every test runs at.
let now = date("2026-10-10T14:40:00-07:00")
let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

/// Claude readings with the 5-hour window resetting at 4:58 PM and the weekly
/// windows on Tue 13 Oct at 7:00 AM, unless overridden.
func claude(
    fiveHour: Double? = 42,
    weekly: Double? = 61,
    fable: Double? = 34,
    fiveHourResetsAt: Date = date("2026-10-10T16:58:00-07:00"),
    weeklyResetsAt: Date = date("2026-10-13T07:00:00-07:00")
) -> ClaudeLimits {
    ClaudeLimits(
        plan: "Max",
        capturedAt: date("2026-10-10T14:37:00-07:00"),
        fiveHour: fiveHour.map { LimitReading(usedPercent: $0, resetsAt: fiveHourResetsAt) },
        sevenDay: weekly.map { LimitReading(usedPercent: $0, resetsAt: weeklyResetsAt) },
        sevenDayFable: fable.map { LimitReading(usedPercent: $0, resetsAt: weeklyResetsAt) }
    )
}

/// Codex readings with a single weekly window resetting Thu 15 Oct at 1:16 PM.
func codex(weekly: Double = 13, resetsAt: Date = date("2026-10-15T13:16:00-07:00")) -> CodexLimits {
    CodexLimits(
        plan: "pro",
        capturedAt: now,
        windows: [CodexWindow(usedPercent: weekly, windowMinutes: 10080, resetsAt: resetsAt)]
    )
}

func snapshot(
    claude: ClaudeLimits? = nil,
    claudeStatusLine: ClaudeLimits? = nil,
    codex: CodexLimits? = nil,
    codexSessionLog: CodexLimits? = nil,
    at time: Date = now
) -> UsageSnapshot {
    UsageEngine.snapshot(
        from: Readings(claude: claude, claudeStatusLine: claudeStatusLine, codex: codex, codexSessionLog: codexSessionLog),
        now: time,
        timeZone: losAngeles
    )
}

/// A file under the repo's `Fixtures/` directory.
func fixtureURL(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // UsageCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appending(path: "Fixtures/\(path)")
}

/// The lines of a recorded JSON-lines fixture, as they arrived on the wire.
func fixtureLines(_ path: String) throws -> [Data] {
    try Data(contentsOf: fixtureURL(path))
        .split(separator: UInt8(ascii: "\n"))
        .map { Data($0) }
}

/// What a conversation with app-server sent and produced while replaying lines.
struct Replay {
    var sent: [Data] = []
    var readings: [CodexAppServerConversation.Reading] = []
    var failures: [String] = []

    /// The new readings, in order, leaving out answers with nothing usable.
    var limits: [CodexLimits] {
        readings.compactMap { if case let .updated(limits) = $0 { limits } else { nil } }
    }

    /// The `method` of every message sent, or "reply" for responses.
    var sentMethods: [String] {
        sent.map { line in
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            return object?["method"] as? String ?? "reply"
        }
    }
}

/// Replays app-server stdout lines through a fresh conversation, all received at `time`.
func replay(_ lines: [Data], at time: Date) -> Replay {
    var conversation = CodexAppServerConversation()
    var result = Replay(sent: conversation.start())
    for line in lines {
        let step = conversation.receive(line, at: time)
        result.sent += step.send
        if let reading = step.reading { result.readings.append(reading) }
        if let failure = step.failure { result.failures.append(failure) }
    }
    return result
}

/// A JSON object edited in place: `json["a", "b"] = 1` sets a nested key and
/// `= nil` removes it.
struct EditableJSON {
    var object: [String: Any]

    subscript(path: String...) -> Any? {
        get { path.dropLast().reduce(object as Any?) { ($0 as? [String: Any])?[$1] }.flatMap { ($0 as? [String: Any])?[path.last!] } }
        set { object = Self.setting(object, Array(path), newValue) }
    }

    private static func setting(_ object: [String: Any], _ path: [String], _ value: Any?) -> [String: Any] {
        var copy = object
        if path.count == 1 {
            copy[path[0]] = value
        } else {
            copy[path[0]] = setting(object[path[0]] as? [String: Any] ?? [:], Array(path.dropFirst()), value)
        }
        return copy
    }
}

/// A recorded JSON object with some edits applied.
func editing(_ json: Data, _ edit: (inout EditableJSON) -> Void) -> Data {
    var editable = EditableJSON(object: (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:])
    edit(&editable)
    return try! JSONSerialization.data(withJSONObject: editable.object)
}
