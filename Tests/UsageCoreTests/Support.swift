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
    claudeUsage: [UsageEntry] = [],
    codexUsage: [UsageEntry] = [],
    at time: Date = now
) -> UsageSnapshot {
    UsageEngine.snapshot(
        from: Readings(claude: claude, claudeStatusLine: claudeStatusLine, codex: codex, codexSessionLog: codexSessionLog,
                       claudeUsage: claudeUsage, codexUsage: codexUsage),
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

/// One assistant line as Claude Code writes it to a transcript, with the
/// fields UsageBar reads (and a few it doesn't).
func transcriptLine(
    id: String,
    at time: String,
    model: String = "claude-opus-5-5",
    input: Int = 0,
    write5m: Int = 0,
    write1h: Int = 0,
    read: Int = 0,
    output: Int = 0,
    speed: String = "standard",
    inferenceGeo: String = "global"
) -> Data {
    let line: [String: Any] = [
        "parentUuid": NSNull(),
        "isSidechain": false,
        "type": "assistant",
        "uuid": UUID().uuidString.lowercased(),
        "timestamp": time,
        "requestId": "req_\(id)",
        "message": [
            "model": model,
            "id": id,
            "type": "message",
            "role": "assistant",
            "content": [],
            "usage": [
                "input_tokens": input,
                "cache_creation_input_tokens": write5m + write1h,
                "cache_read_input_tokens": read,
                "output_tokens": output,
                "service_tier": "standard",
                "cache_creation": ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h],
                "speed": speed,
                "inference_geo": inferenceGeo,
            ],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: line)
}

/// Claude Code's usage in transcript lines, read and de-duplicated as the app does.
func claudeUsage(_ lines: [Data]) -> [UsageEntry] {
    var ledger = UsageLedger()
    for line in lines {
        ledger.add(ClaudeTranscript.entries(in: line + Data("\n".utf8)))
    }
    return ledger.entries
}

/// Token counts in Codex's shape. Cached input and cache writes are part of
/// `input`; reasoning is part of `output`.
func codexTokens(input: Int = 0, cached: Int = 0, write: Int = 0, output: Int = 0, reasoning: Int = 0) -> [String: Int] {
    [
        "input_tokens": input,
        "cached_input_tokens": cached,
        "cache_write_input_tokens": write,
        "output_tokens": output,
        "reasoning_output_tokens": reasoning,
        "total_tokens": input + output,
    ]
}

/// Codex rollout lines as Codex writes them, with the fields UsageBar reads
/// (and a few it doesn't).
enum Rollout {
    static func sessionMeta(id: String, at time: String) -> Data {
        json([
            "timestamp": time, "type": "session_meta",
            "payload": ["id": id, "session_id": id, "timestamp": time, "source": "vscode",
                        "cli_version": "0.162.0-alpha.17.2", "model_provider": "openai"],
        ])
    }

    static func turnContext(model: String, at time: String) -> Data {
        json([
            "timestamp": time, "type": "turn_context",
            "payload": ["turn_id": UUID().uuidString.lowercased(), "model": model, "effort": "medium",
                        "service_tier": NSNull(), "timezone": "America/Los_Angeles"],
        ])
    }

    /// A `token_count` event: the session's running total and the last
    /// response's usage. With neither, `info` is null, as Codex writes it
    /// before the first response.
    static func tokenCount(at time: String, total: [String: Any]?, last: [String: Any]?) -> Data {
        var info: Any = NSNull()
        if total != nil || last != nil {
            var fields: [String: Any] = ["model_context_window": 258_400]
            if let total { fields["total_token_usage"] = total }
            if let last { fields["last_token_usage"] = last }
            info = fields
        }
        return json([
            "timestamp": time, "type": "event_msg",
            "payload": ["type": "token_count", "info": info, "rate_limits": NSNull()],
        ])
    }

    /// One step of a session: a new turn on a model, or one model response.
    enum Step {
        case turn(model: String, at: String)
        case response(at: String, [String: Int])
    }

    /// A whole rollout file: its `session_meta` line, then each step, with
    /// the running totals Codex keeps.
    static func session(id: String = "thread-1", _ steps: [Step]) -> [Data] {
        var total = codexTokens()
        var lines: [Data] = []
        for step in steps {
            switch step {
            case let .turn(model, time):
                if lines.isEmpty { lines.append(sessionMeta(id: id, at: time)) }
                lines.append(turnContext(model: model, at: time))
            case let .response(time, tokens):
                if lines.isEmpty { lines.append(sessionMeta(id: id, at: time)) }
                total.merge(tokens, uniquingKeysWith: +)
                lines.append(tokenCount(at: time, total: total, last: tokens))
            }
        }
        return lines
    }

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

/// Codex's usage in rollout files (one array of lines per file), each file
/// read in order as the app does.
func codexUsage(_ files: [[Data]]) -> [UsageEntry] {
    var ledger = UsageLedger()
    for (index, lines) in files.enumerated() {
        var parser = CodexRollout.Parser(path: "/sessions/rollout-\(index).jsonl")
        ledger.add(parser.entries(in: lines.reduce(Data()) { $0 + $1 + Data("\n".utf8) }))
    }
    return ledger.entries
}
