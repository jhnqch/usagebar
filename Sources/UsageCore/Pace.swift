import Foundation

/// How a limit window's use compares with the time that has passed in it:
/// the pace tick and the prediction under the meter.
struct Pace {
    /// The fraction of the window that has elapsed, 0...1.
    var elapsed: Double
    private var reading: LimitReading
    private var length: TimeInterval
    private var clock: Clock

    /// Before this much of a window has passed, extrapolating is noise.
    static let quietFraction = 0.1

    /// The window runs from its reset minus its length to its reset, in
    /// absolute time, so a DST change inside it doesn't move its start.
    /// Nil once the reset has passed: the next window's start isn't known.
    init?(reading: LimitReading, minutes: Int, clock: Clock) {
        let length = TimeInterval(minutes) * 60
        guard length > 0, reading.resetsAt > clock.now else { return nil }
        let start = reading.resetsAt - length
        elapsed = min(max(clock.now.timeIntervalSince(start) / length, 0), 1)
        self.reading = reading
        self.length = length
        self.clock = clock
    }

    /// Where use is headed at this pace. Projected use at the reset is
    /// used % ÷ elapsed fraction. From 100% the limit comes first, when the
    /// rest of it runs out at the average rate so far; a limit that rounds
    /// to after the reset reads as below pace, at about 100%. A maxed window
    /// says so, however early. Otherwise nil in the window's first 10%.
    var prediction: PacePrediction? {
        let used = reading.usedPercent
        if Level(percent: used) == .maxed {
            return PacePrediction(text: "Limit reached", isAhead: false)
        }
        guard elapsed >= Self.quietFraction else { return nil }
        let projected = used / elapsed
        if projected >= 100 {
            let percentPerSecond = used / (elapsed * length)
            let limit = clock.approximately(clock.now + (100 - used) / percentPerSecond)
            if limit.date <= reading.resetsAt {
                return PacePrediction(text: "Ahead of pace: limit around \(limit.text)", isAhead: true)
            }
        }
        return PacePrediction(text: "Below pace: about \(Int(min(max(projected, 0), 100).rounded()))% by reset", isAhead: false)
    }
}
