import Foundation

/// The latest raw readings from every source. The engine turns these, plus a
/// clock, into a `UsageSnapshot`. A missing reading means "no data".
public struct Readings: Codable, Equatable, Sendable {
    public var claude: ClaudeLimits?
    public var codex: CodexLimits?

    public init(claude: ClaudeLimits? = nil, codex: CodexLimits? = nil) {
        self.claude = claude
        self.codex = codex
    }
}

/// One limit window as a source reports it.
public struct LimitReading: Codable, Equatable, Sendable {
    /// Percent of the window used, 0–100.
    public var usedPercent: Double
    public var resetsAt: Date

    public init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Claude's limit windows: 5-hour session, weekly (all models), weekly Fable.
public struct ClaudeLimits: Codable, Equatable, Sendable {
    /// Plan name, e.g. "Max".
    public var plan: String?
    public var capturedAt: Date
    public var fiveHour: LimitReading?
    public var sevenDay: LimitReading?
    public var sevenDayFable: LimitReading?

    public init(
        plan: String? = nil,
        capturedAt: Date,
        fiveHour: LimitReading? = nil,
        sevenDay: LimitReading? = nil,
        sevenDayFable: LimitReading? = nil
    ) {
        self.plan = plan
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayFable = sevenDayFable
    }
}

/// Codex's limit windows: zero or more, each with its own length.
public struct CodexLimits: Codable, Equatable, Sendable {
    /// Plan type as Codex reports it, e.g. "pro".
    public var plan: String?
    public var capturedAt: Date
    public var windows: [CodexWindow]

    public init(plan: String? = nil, capturedAt: Date, windows: [CodexWindow]) {
        self.plan = plan
        self.capturedAt = capturedAt
        self.windows = windows
    }
}

public struct CodexWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

// MARK: - Shifting in time

extension Readings {
    func shifted(by offset: TimeInterval) -> Readings {
        Readings(claude: claude?.shifted(by: offset), codex: codex?.shifted(by: offset))
    }
}

extension LimitReading {
    func shifted(by offset: TimeInterval) -> LimitReading {
        LimitReading(usedPercent: usedPercent, resetsAt: resetsAt + offset)
    }
}

extension ClaudeLimits {
    func shifted(by offset: TimeInterval) -> ClaudeLimits {
        ClaudeLimits(
            plan: plan,
            capturedAt: capturedAt + offset,
            fiveHour: fiveHour?.shifted(by: offset),
            sevenDay: sevenDay?.shifted(by: offset),
            sevenDayFable: sevenDayFable?.shifted(by: offset)
        )
    }
}

extension CodexLimits {
    func shifted(by offset: TimeInterval) -> CodexLimits {
        CodexLimits(
            plan: plan,
            capturedAt: capturedAt + offset,
            windows: windows.map {
                CodexWindow(usedPercent: $0.usedPercent, windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt + offset)
            }
        )
    }
}

// MARK: - Tolerant decoding
//
// Readings come from formats that can change without notice. A missing,
// renamed or mistyped field drops only the row it feeds (which then shows
// "—"); it never fails the whole readings file.

extension Readings {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = try? c.decodeIfPresent(ClaudeLimits.self, forKey: .claude)
        codex = try? c.decodeIfPresent(CodexLimits.self, forKey: .codex)
    }
}

extension ClaudeLimits {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        fiveHour = try? c.decodeIfPresent(LimitReading.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(LimitReading.self, forKey: .sevenDay)
        sevenDayFable = try? c.decodeIfPresent(LimitReading.self, forKey: .sevenDayFable)
    }
}

extension CodexLimits {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        windows = ((try? c.decodeIfPresent([Lenient<CodexWindow>].self, forKey: .windows)) ?? [])
            .compactMap(\.value)
    }
}

/// Decodes a `T`, or nil when that element is malformed, so one bad array
/// element doesn't sink its siblings.
private struct Lenient<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
