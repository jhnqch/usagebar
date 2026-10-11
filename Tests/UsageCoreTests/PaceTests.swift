import Foundation
import Testing
import UsageCore

@Suite("Pace ticks")
struct PaceTickTests {
    @Test("each meter's tick sits at the elapsed fraction of its window: time since reset minus length, over length")
    func sampleTicks() throws {
        let fixture = try loadFixture("sample")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        // Sat 2:40 PM. 5-hour window 11:58 AM to 4:58 PM: 162 of 300 minutes.
        // Weekly windows Tue 6 Oct 7:00 AM to Tue 13 Oct: 4d 7h 40m = 6220 of 10080 minutes.
        // Codex Thu 8 Oct 1:16 PM to Thu 15 Oct: 2d 1h 24m = 2964 of 10080 minutes.
        let claude = snapshot.claude.meters
        let fiveHour: Double = 162.0 / 300, weekly: Double = 6220.0 / 10080, codex: Double = 2964.0 / 10080
        #expect(claude.map(\.elapsed) == [fiveHour, weekly, weekly])
        #expect(claude.map(\.elapsedText) == ["54% of window elapsed", "62% of window elapsed", "62% of window elapsed"])
        #expect(snapshot.codex.meters.map(\.elapsed) == [codex])
        #expect(snapshot.codex.meters.map(\.elapsedText) == ["29% of window elapsed"])
    }

    @Test("a Codex window's length comes from the reading: a 5-hour and a 1-day window")
    func codexWindowLengths() {
        let limits = CodexLimits(plan: "pro", capturedAt: now, windows: [
            // 4:10 PM reset: started 11:10 AM, 210 of 300 minutes ago.
            CodexWindow(usedPercent: 20, windowMinutes: 300, resetsAt: date("2026-10-10T16:10:00-07:00")),
            // Sun 8:40 AM reset: started Sat 8:40 AM, 360 of 1440 minutes ago.
            CodexWindow(usedPercent: 10, windowMinutes: 1440, resetsAt: date("2026-10-11T08:40:00-07:00")),
        ])
        let meters = snapshot(codex: limits).codex.meters
        #expect(meters.map(\.elapsed) == [0.7, 0.25])
        #expect(meters.map(\.elapsedText) == ["70% of window elapsed", "25% of window elapsed"])
    }

    @Test("a reset more than a window away puts the tick at the start, not before it")
    func clampedAtStart() {
        // A weekly reset 8 days out: its window hasn't started yet.
        let meter = snapshot(claude: claude(weeklyResetsAt: date("2026-10-18T14:40:00-07:00"))).claude.meters[1]
        #expect(meter.elapsed == 0)
        #expect(meter.elapsedText == "0% of window elapsed")
    }

    @Test("a window whose reset has passed has no tick: the next window's start isn't known")
    func passedReset() {
        let meter = snapshot(claude: claude(fiveHour: 80, fiveHourResetsAt: date("2026-10-10T14:00:00-07:00"))).claude.meters[0]
        #expect(meter.percentText == "0%")
        #expect(meter.elapsed == nil)
        #expect(meter.elapsedText == nil)
    }

    @Test("a window with no reading has no tick")
    func noReading() {
        let meter = snapshot(claude: claude(fable: nil)).claude.meters[2]
        #expect(meter.elapsed == nil)
        #expect(meter.elapsedText == nil)
    }
}

@Suite("Pace predictions")
struct PacePredictionTests {
    @Test("projected use under 100% says where use will be at reset: used ÷ elapsed fraction")
    func belowPace() throws {
        let fixture = try loadFixture("sample")
        let snapshot = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone)
        // 42% at 54% elapsed → 77.8%; 61% at 61.7% → 98.9%; 34% → 55.1%; Codex 13% at 29.4% → 44.2%.
        #expect(snapshot.claude.meters.map(\.prediction) == [
            PacePrediction(text: "Below pace: about 78% by reset", isAhead: false),
            PacePrediction(text: "Below pace: about 99% by reset", isAhead: false),
            PacePrediction(text: "Below pace: about 55% by reset", isAhead: false),
        ])
        #expect(snapshot.codex.meters.map(\.prediction) == [PacePrediction(text: "Below pace: about 44% by reset", isAhead: false)])
    }

    @Test(
        "no prediction in a window's first 10%, but the tick still shows",
        arguments: [
            // The 5-hour window resets at 4:58 PM, so it started at 11:58 AM; 10% is 30 minutes.
            ("2026-10-10T11:58:01-07:00", 1.0 / 18000, nil),
            ("2026-10-10T12:20:00-07:00", 22.0 / 300, nil),
            ("2026-10-10T12:27:59-07:00", 1799.0 / 18000, nil),
            ("2026-10-10T12:28:00-07:00", 0.1, "Below pace: about 50% by reset"),
        ] as [(String, Double, String?)]
    )
    func quietStart(at time: String, elapsed: Double, prediction: String?) {
        let meter = snapshot(claude: claude(fiveHour: 5), at: date(time)).claude.meters[0]
        #expect(meter.elapsed == elapsed)
        #expect(meter.prediction?.text == prediction)
    }

    @Test("a window that starts right now has its tick at the start and no prediction")
    func elapsedZero() {
        let meter = snapshot(claude: claude(fiveHour: 0, fiveHourResetsAt: date("2026-10-10T19:40:00-07:00"))).claude.meters[0]
        #expect(meter.elapsed == 0)
        #expect(meter.elapsedText == "0% of window elapsed")
        #expect(meter.prediction == nil)
    }

    @Test("projected use at 100% or more gives the time of the limit, rounded to 5 minutes when it's today")
    func aheadToday() throws {
        let fixture = try loadFixture("near")
        let meter = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone).claude.meters[0]
        // 93% at 2:40 PM, 193 minutes into a window that started at 11:27 AM:
        // 7% more at 93/193 % a minute is 14.5 minutes, so 2:54:32 PM.
        #expect(meter.prediction == PacePrediction(text: "Ahead of pace: limit around 2:55 PM", isAhead: true))
    }

    @Test("a limit on another day gives the day and the nearest hour")
    func aheadAnotherDay() {
        // 68% after 6220 of 10080 minutes is 109% by the reset. The other 32%
        // at 68/6220 % a minute takes 2927 minutes: Mon 3:27 PM.
        let meter = snapshot(claude: claude(weekly: 68)).claude.meters[1]
        #expect(meter.prediction == PacePrediction(text: "Ahead of pace: limit around Mon 3 PM", isAhead: true))
    }

    @Test("a limit just before midnight that rounds into tomorrow names the day")
    func aheadPastMidnight() {
        // 5-hour window 9:00 PM to 2:00 AM. 67.4% at 11:00 PM, 120 minutes in,
        // runs out 178 minutes in: 11:58 PM, which rounds to midnight.
        let meter = snapshot(
            claude: claude(fiveHour: 67.4, fiveHourResetsAt: date("2026-10-11T02:00:00-07:00")),
            at: date("2026-10-10T23:00:00-07:00")
        ).claude.meters[0]
        #expect(meter.prediction?.text == "Ahead of pace: limit around Sun 12 AM")
    }

    @Test(
        "a limit that rounds to after the reset reads as below pace, at no more than 100%",
        arguments: [
            // Weekly reset Tue 6:50 AM: 61.82% after 6230 minutes runs out at Tue 6:47 AM,
            // which rounds to 7 AM. Projected 100.02%.
            (61.82, "2026-10-13T06:50:00-07:00", 1, "Below pace: about 100% by reset"),
            // 5-hour reset 4:58 PM: 54.05% after 162 minutes runs out 299.7 minutes
            // in, 4:57:43 PM, which rounds to 5:00 PM. Projected 100.09%.
            (54.05, "2026-10-10T16:58:00-07:00", 0, "Below pace: about 100% by reset"),
            // 55% runs out 294.5 minutes in, 4:52:33 PM, which rounds to 4:55 PM.
            (55, "2026-10-10T16:58:00-07:00", 0, "Ahead of pace: limit around 4:55 PM"),
        ] as [(Double, String, Int, String)]
    )
    func roundsPastReset(used: Double, resetsAt: String, meterIndex: Int, text: String) {
        let limits = meterIndex == 0
            ? claude(fiveHour: used, fiveHourResetsAt: date(resetsAt))
            : claude(weekly: used, weeklyResetsAt: date(resetsAt))
        #expect(snapshot(claude: limits).claude.meters[meterIndex].prediction?.text == text)
    }

    @Test("a maxed window says the limit is reached, and its reset line just says when it resets")
    func maxed() throws {
        let fixture = try loadFixture("maxed")
        let meter = UsageEngine.snapshot(from: fixture.readings, now: fixture.now, timeZone: fixture.timeZone).claude.meters[0]
        #expect(meter.prediction == PacePrediction(text: "Limit reached", isAhead: false))
        #expect(meter.resetText == "Resets in 1h 05m (3:45 PM)")
        // The window started at 10:45 AM: 235 of 300 minutes.
        #expect(meter.elapsedText == "78% of window elapsed")
    }

    @Test("a window maxed in its first 10% still says the limit is reached")
    func maxedEarly() {
        // Weekly window reset Sat 17 Oct 7:00 AM: started Sat 10 Oct 7:00 AM, 7h 40m ago (4.6%).
        let meter = snapshot(claude: claude(weekly: 100, weeklyResetsAt: date("2026-10-17T07:00:00-07:00"))).claude.meters[1]
        #expect(meter.prediction?.text == "Limit reached")
        #expect(meter.resetText == "Resets Sat 7:00 AM")
    }

    @Test("a window whose reset has passed reads 0% and makes no prediction")
    func passedReset() {
        let meter = snapshot(claude: claude(fiveHour: 100, fiveHourResetsAt: date("2026-10-10T14:00:00-07:00"))).claude.meters[0]
        #expect(meter.percentText == "0%")
        #expect(meter.prediction == nil)
    }

    @Test("a window with no reading makes no prediction")
    func noReading() {
        #expect(snapshot(claude: claude(fable: nil)).claude.meters[2].prediction == nil)
    }
}

@Suite("Pace across a DST change")
struct PaceDSTTests {
    @Test("a weekly window over the November change: elapsed and the limit time count real hours")
    func weeklyOverFallBack() {
        // Clocks go back at 2 AM on Sun 1 Nov 2026. The window ending Tue 3 Nov
        // 7:00 AM PST started 168 hours earlier: Tue 27 Oct 8:00 AM PDT. At Sat
        // noon PDT, 100 of 168 hours have passed.
        let meter = snapshot(
            claude: claude(weekly: 75, weeklyResetsAt: date("2026-11-03T07:00:00-08:00")),
            at: date("2026-10-31T12:00:00-07:00")
        ).claude.meters[1]
        let elapsed: Double = 100.0 / 168
        #expect(meter.elapsed == elapsed)
        #expect(meter.elapsedText == "60% of window elapsed")
        // 75% in 100 hours: the other 25% takes 33h 20m, which is Sun 8:20 PM
        // PST (9:20 PM on the clock it started from).
        #expect(meter.prediction?.text == "Ahead of pace: limit around Sun 8 PM")
    }

    @Test(
        "a 5-hour window over the repeated hour: 11 PM PDT to 3 AM PST is 5 hours",
        arguments: [
            // At the second 1:30 AM (PST), 3.5 of 5 hours have passed (0.7).
            (49.0, "Below pace: about 70% by reset"),
            // 77% in 3.5 hours: the other 23% takes 62.7 minutes, 2:32:44 AM PST.
            (77.0, "Ahead of pace: limit around 2:35 AM"),
        ]
    )
    func fiveHourOverFallBack(used: Double, text: String) {
        let meter = snapshot(
            claude: claude(fiveHour: used, fiveHourResetsAt: date("2026-11-01T03:00:00-08:00")),
            at: date("2026-11-01T01:30:00-08:00")
        ).claude.meters[0]
        #expect(meter.elapsed == 0.7)
        #expect(meter.prediction?.text == text)
    }
}
