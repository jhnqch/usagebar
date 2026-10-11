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

func snapshot(claude: ClaudeLimits? = nil, codex: CodexLimits? = nil, at time: Date = now) -> UsageSnapshot {
    UsageEngine.snapshot(from: Readings(claude: claude, codex: codex), now: time, timeZone: losAngeles)
}
