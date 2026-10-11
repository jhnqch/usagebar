import Foundation

/// Dollars per million tokens, by kind of token.
public struct TokenRates: Equatable, Sendable {
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var output: Double

    public init(input: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double, output: Double) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    func dollars(_ tokens: TokenCounts) -> Double {
        let perMillion = Double(tokens.input) * input
            + Double(tokens.cacheWrite5m) * cacheWrite5m
            + Double(tokens.cacheWrite1h) * cacheWrite1h
            + Double(tokens.cacheRead) * cacheRead
            + Double(tokens.output) * output
        return perMillion / 1_000_000
    }
}

/// One model's API prices.
public struct ModelPrice: Equatable, Sendable {
    /// The model id, e.g. "claude-opus-5-5".
    public var id: String
    /// Its short name for the legend, e.g. "Opus 5.5".
    public var name: String
    /// The model line it belongs to ("opus", "fable", ...), which picks its
    /// chart colour.
    public var family: String
    public var rates: TokenRates
    /// Higher rates for a long prompt, where the model has them.
    public var longContext: LongContextRates?
    /// Rates in fast mode, where it's offered.
    public var fast: TokenRates?

    public init(id: String, name: String, family: String, rates: TokenRates,
                longContext: LongContextRates? = nil, fast: TokenRates? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.rates = rates
        self.longContext = longContext
        self.fast = fast
    }

    /// What one reply would have cost through the API.
    public func dollars(_ entry: UsageEntry) -> Double {
        if entry.fast, let fast { return fast.dollars(entry.tokens) }
        if let longContext, entry.tokens.prompt > longContext.threshold {
            return longContext.rates.dollars(entry.tokens)
        }
        return rates.dollars(entry.tokens)
    }

}

/// Rates for a request whose prompt (every input token, cache reads and
/// writes included) is over `threshold` tokens. Each request is priced on
/// its own.
public struct LongContextRates: Equatable, Sendable {
    public var threshold: Int
    public var rates: TokenRates

    public init(threshold: Int, rates: TokenRates) {
        self.threshold = threshold
        self.rates = rates
    }
}

/// Model prices by id. Models missing from the table count their tokens but
/// no dollars.
public struct PriceTable: Equatable, Sendable {
    /// Newest first within each model line: the first of a line present in a
    /// chart gets the line's colour.
    public let models: [ModelPrice]
    private let byID: [String: ModelPrice]

    public init(models: [ModelPrice]) {
        self.models = models
        byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func == (lhs: PriceTable, rhs: PriceTable) -> Bool {
        lhs.models == rhs.models
    }

    /// The price for a model id as logged. Matches the bare id, so a dated
    /// snapshot ("claude-haiku-4-5-20251001"), a context-size tag
    /// ("claude-opus-5-5[1m]") or a cloud prefix ("us.anthropic.…") still
    /// finds its model.
    public func price(for model: String) -> ModelPrice? {
        if let exact = byID[model] { return exact }
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let claude = id.range(of: "claude-") { id = String(id[claude.lowerBound...]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        id = id.replacing(/-v\d+(:\d+)?$/, with: "")
        id = id.replacing(/-\d{8}$/, with: "")
        return byID[id]
    }
}
