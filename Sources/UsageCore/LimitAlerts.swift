import Foundation

/// A notification to post: a window at the warning threshold (90% unless
/// the Alerts settings say otherwise) or more, or a maxed window that has
/// reset.
public struct LimitAlert: Equatable, Sendable, Identifiable {
    /// Stable for one window, cycle and kind, so posting it twice replaces
    /// the first.
    public var id: String
    /// "Claude 5-hour session at 92%", "Claude 5-hour limit reset".
    public var title: String
    /// "Resets 4:58 PM · ahead of pace: limit around 3:15 PM", "You're good to go."
    public var body: String
}

/// Which alerts have fired, one entry per window cycle: the engine's input
/// and output, so it stays pure. The app saves it between launches.
public struct AlertMemory: Equatable, Sendable {
    public private(set) var cycles: [Cycle]

    public init(cycles: [Cycle] = []) {
        self.cycles = cycles
    }

    /// One reset cycle of one window, known by its reset time.
    public struct Cycle: Equatable, Sendable {
        /// The meter's id, e.g. "claude.fiveHour".
        public var window: String
        /// What its alerts call the limit, e.g. "Claude 5-hour limit": kept
        /// so the reset is announced even once the window isn't reported.
        public var name: String
        /// The latest reset time a reading of this cycle gave.
        public var resetsAt: Date
        /// The threshold alert (or "limit reached") has fired, or was due
        /// while "limit reached" alerts were off.
        public var warned = false
        /// The window was seen at 100%, so its reset gets an alert.
        public var maxed = false
        /// The reset alert has fired.
        public var resetAnnounced = false
    }

    /// The cycles matching `belongs`, and the rest.
    func partitioned(by belongs: (Cycle) -> Bool) -> (matching: [Cycle], rest: AlertMemory) {
        (cycles.filter(belongs), AlertMemory(cycles: cycles.filter { !belongs($0) }))
    }

    /// This memory with `others` added after its own cycles.
    func adding(_ others: [Cycle]) -> AlertMemory {
        AlertMemory(cycles: cycles + others)
    }

    /// The saved file's name in UsageBar's support directory.
    public static let fileName = "alerts.json"

    /// The memory a saved file holds. An unreadable file is an empty memory,
    /// and an unreadable entry is left out. Times are seconds since 1970,
    /// which round-trip exactly, whatever a source reported.
    public static func decode(_ data: Data) -> AlertMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let file = try? decoder.decode(File.self, from: data)
        return AlertMemory(cycles: file?.cycles.compactMap(\.value) ?? [])
    }

    /// The file to save.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(EncodedFile(cycles: cycles))) ?? Data()
    }

    private struct File: Decodable {
        var cycles: [Lenient<Cycle>]
    }

    private struct EncodedFile: Encodable {
        var cycles: [Cycle]
    }
}

extension AlertMemory.Cycle: Codable {
    private enum CodingKeys: String, CodingKey {
        case window, name, resetsAt, warned, maxed, resetAnnounced
    }

    /// The window, its name and its reset are needed; a missing flag is unset.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try c.decode(String.self, forKey: .window)
        name = try c.decode(String.self, forKey: .name)
        resetsAt = try c.decode(Date.self, forKey: .resetsAt)
        warned = (try? c.decodeIfPresent(Bool.self, forKey: .warned)) ?? false
        maxed = (try? c.decodeIfPresent(Bool.self, forKey: .maxed)) ?? false
        resetAnnounced = (try? c.decodeIfPresent(Bool.self, forKey: .resetAnnounced)) ?? false
    }
}

/// The alerts one evaluation fires.
enum LimitAlerts {
    /// What a window's alerts call it.
    struct Names {
        /// What's at 90%: "Claude 5-hour session".
        var near: String
        /// What's reached or reset: "Claude 5-hour limit".
        var limit: String

        init(near: String? = nil, limit: String) {
            self.near = near ?? limit
            self.limit = limit
        }
    }

    /// A window as the alerts see it.
    struct Window {
        var id: String
        var names: Names
        /// The reading as of now: 0% once its reset has passed.
        var reading: LimitReading?
        var prediction: PacePrediction?
        /// Its provider's alerts are off: its readings still keep its
        /// cycles' reset times current, but it opens no cycle, and its
        /// resets pass without an alert.
        var muted = false
    }

    /// A reset noticed later than this after the fact says when it was.
    static let lateReset: TimeInterval = 10 * 60

    /// How long after its reset a cycle is remembered: a week, the longest
    /// window. A reset noticed later than that isn't announced.
    static let remembered: TimeInterval = 7 * 24 * 60 * 60

    /// Reset alerts for maxed cycles that have ended, then threshold alerts
    /// for current cycles, each in the popover's order. A window warns once a
    /// cycle, at or above `settings.threshold`, however often the threshold
    /// changes; `settings` can also turn either alert kind off.
    static func evaluate(
        _ windows: [Window], memory: AlertMemory, settings: AlertSettings = AlertSettings(), clock: Clock
    ) -> (alerts: [LimitAlert], memory: AlertMemory) {
        var cycles = memory.cycles.filter { clock.now.timeIntervalSince($0.resetsAt) <= remembered }
        // A reading whose reset has passed is the last cycle's, read as 0%.
        let live = windows.reduce(into: [String: LimitReading]()) { live, window in
            if let reading = window.reading, reading.resetsAt > clock.now { live[window.id] = reading }
        }
        // A cycle ends at the latest reset time any of its readings gave.
        for index in cycles.indices {
            if let reading = live[cycles[index].window], cycles[index].isCycle(of: reading) {
                cycles[index].resetsAt = max(cycles[index].resetsAt, reading.resetsAt)
            }
        }

        var alerts: [LimitAlert] = []
        // A maxed cycle has reset once its reset time passes, or once a later
        // cycle shows up (a limit restored early). A window that's no longer
        // reported resets on time.
        let order = Dictionary(windows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ cycle: AlertMemory.Cycle) -> (Int, Date) { (order[cycle.window] ?? order.count, cycle.resetsAt) }
        let ended = cycles.indices
            .filter { index in
                let cycle = cycles[index]
                guard cycle.maxed, !cycle.resetAnnounced else { return false }
                let superseded = live[cycle.window].map { $0.resetsAt > cycle.resetsAt + UsageEngine.sameWindowTolerance } ?? false
                return cycle.resetsAt <= clock.now || superseded
            }
            .sorted { rank(cycles[$0]) < rank(cycles[$1]) }
        // With reset alerts off a reset still counts as announced, so turning
        // them back on doesn't announce it late.
        let muted = Set(windows.filter(\.muted).map(\.id))
        for index in ended {
            cycles[index].resetAnnounced = true
            if settings.limitReset, !muted.contains(cycles[index].window) { alerts.append(reset(cycles[index], clock: clock)) }
        }

        for window in windows where !window.muted {
            guard let reading = live[window.id], Level(percent: reading.usedPercent, warningAt: settings.warningAt) != .normal else { continue }
            let index = cycles.firstIndex { $0.window == window.id && $0.isCycle(of: reading) } ?? {
                cycles.append(AlertMemory.Cycle(window: window.id, name: window.names.limit, resetsAt: reading.resetsAt))
                return cycles.count - 1
            }()
            let maxed = Level(percent: reading.usedPercent) == .maxed
            if maxed { cycles[index].maxed = true }
            // A window first seen maxed says "limit reached", unless those
            // alerts are off; either way the cycle has had its one warning.
            if !cycles[index].warned {
                cycles[index].warned = true
                if !maxed || settings.limitReached { alerts.append(near(window, reading, clock: clock)) }
            }
        }
        return (alerts, AlertMemory(cycles: cycles))
    }

    /// "Claude 5-hour session at 92%", with the reset and the pace; "Claude
    /// 5-hour limit reached" for a window first seen maxed.
    private static func near(_ window: Window, _ reading: LimitReading, clock: Clock) -> LimitAlert {
        let resets = "Resets \(clock.time(reading.resetsAt))"
        let id = "\(window.id).near.\(reading.resetsAt.timeIntervalSince1970)"
        if Level(percent: reading.usedPercent) == .maxed {
            return LimitAlert(id: id, title: "\(window.names.limit) reached", body: resets)
        }
        let pace = window.prediction.map { " · " + $0.text.prefix(1).lowercased() + $0.text.dropFirst() } ?? ""
        return LimitAlert(id: id, title: "\(window.names.near) at \(UsageEngine.percentText(reading.usedPercent))", body: resets + pace)
    }

    /// "Claude 5-hour limit reset", "You're good to go."; when noticed late
    /// (the Mac was asleep), when it reset.
    private static func reset(_ cycle: AlertMemory.Cycle, clock: Clock) -> LimitAlert {
        let when: String
        if clock.now.timeIntervalSince(cycle.resetsAt) <= lateReset {
            when = ""
        } else if clock.calendar.isDate(cycle.resetsAt, inSameDayAs: clock.now) {
            when = "Reset at \(clock.time(cycle.resetsAt)). "
        } else {
            when = "Reset \(clock.time(cycle.resetsAt)). "
        }
        return LimitAlert(
            id: "\(cycle.window).reset.\(cycle.resetsAt.timeIntervalSince1970)",
            title: "\(cycle.name) reset",
            body: when + "You're good to go."
        )
    }
}

extension AlertMemory.Cycle {
    /// Whether a reading belongs to this cycle: resets this close together
    /// are one window, as when merging Claude's two sources.
    func isCycle(of reading: LimitReading) -> Bool {
        abs(reading.resetsAt.timeIntervalSince(resetsAt)) <= UsageEngine.sameWindowTolerance
    }
}

extension AlertMemory.Cycle {
    /// The cycle with a reset that has passed by `now` marked announced, so
    /// it's never announced: for a provider that was off at the time.
    func silencingReset(at now: Date) -> AlertMemory.Cycle {
        var copy = self
        if maxed, resetsAt <= now { copy.resetAnnounced = true }
        return copy
    }
}
