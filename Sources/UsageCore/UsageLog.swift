import Foundation

/// Token counts for one message, by how they're priced.
public struct TokenCounts: Equatable, Sendable {
    /// Uncached input.
    public var input: Int
    /// Input written to the 5-minute prompt cache.
    public var cacheWrite5m: Int
    /// Input written to the 1-hour prompt cache (priced higher).
    public var cacheWrite1h: Int
    /// Input read from the prompt cache.
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    /// Every token, cache reads included.
    public var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    /// The prompt's length: every input token, cached or not.
    public var prompt: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }

    /// Each count's larger value: a streamed message is logged several times
    /// as it grows, so the largest count is the final one. The cache writes
    /// are one total split two ways, so they come as a pair from one copy:
    /// the one with more writes or, for the same writes, more of them
    /// 1-hour (a copy without the split reads them all as 5-minute).
    func merged(with other: TokenCounts) -> TokenCounts {
        let writes = (cacheWrite5m + cacheWrite1h, cacheWrite1h) >= (other.cacheWrite5m + other.cacheWrite1h, other.cacheWrite1h)
            ? self : other
        return TokenCounts(
            input: max(input, other.input),
            cacheWrite5m: writes.cacheWrite5m,
            cacheWrite1h: writes.cacheWrite1h,
            cacheRead: max(cacheRead, other.cacheRead),
            output: max(output, other.output)
        )
    }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output
        )
    }
}

/// One model reply's usage, from a local log.
public struct UsageEntry: Equatable, Sendable {
    /// The message id that identifies the reply across log lines and files.
    public var id: String
    public var timestamp: Date
    /// The model id as logged, e.g. "claude-opus-5-5".
    public var model: String
    public var tokens: TokenCounts
    /// Whether it ran in fast mode, which is priced higher.
    public var fast: Bool
    /// Whether it ran with US-only inference, which costs 1.1x.
    public var usOnly: Bool

    public init(id: String, timestamp: Date, model: String, tokens: TokenCounts, fast: Bool = false, usOnly: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.fast = fast
        self.usOnly = usOnly
    }

    func shifted(by offset: TimeInterval) -> UsageEntry {
        var copy = self
        copy.timestamp += offset
        return copy
    }
}

/// Usage entries de-duplicated by message id. Claude Code logs a reply once
/// per content block while it streams, each line carrying the usage so far,
/// and a resumed or forked session copies earlier replies into a new file.
/// Each reply counts once, with its final (largest) counts, at the time it
/// was first logged.
public struct UsageLedger: Equatable, Sendable {
    private var byID: [String: UsageEntry] = [:]

    public init() {}

    public mutating func add(_ entry: UsageEntry) {
        guard let known = byID[entry.id] else {
            byID[entry.id] = entry
            return
        }
        byID[entry.id] = UsageEntry(
            id: entry.id,
            timestamp: min(known.timestamp, entry.timestamp),
            model: known.model,
            tokens: known.tokens.merged(with: entry.tokens),
            fast: known.fast || entry.fast,
            usOnly: known.usOnly || entry.usOnly
        )
    }

    public mutating func add(_ entries: [UsageEntry]) {
        for entry in entries { add(entry) }
    }

    /// Forgets replies logged before `date`.
    public mutating func removeEntries(before date: Date) {
        byID = byID.filter { $0.value.timestamp >= date }
    }

    /// Every reply, oldest first.
    public var entries: [UsageEntry] {
        byID.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
    }

    public var count: Int { byID.count }
}
