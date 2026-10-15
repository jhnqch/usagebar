import Foundation

/// The latest raw readings from every source, one value per provider in
/// display order. The engine turns these, plus a clock, into a
/// `UsageSnapshot`. A missing reading means "no data".
public struct Readings: Equatable, Sendable {
    public private(set) var providers: [any Provider]

    public init(_ providers: [any Provider] = []) {
        self.providers = providers
    }

    /// Changes the readings of the provider of type `P`. Does nothing when
    /// that provider isn't there.
    public mutating func update<P: Provider>(_ type: P.Type, _ change: (inout P) -> Void) {
        guard let index = providers.firstIndex(where: { $0 is P }), var provider = providers[index] as? P else { return }
        change(&provider)
        providers[index] = provider
    }

    /// The readings of the provider of type `P`, if it's there.
    public subscript<P: Provider>(_ type: P.Type) -> P? {
        providers.lazy.compactMap { $0 as? P }.first
    }

    public static func == (lhs: Readings, rhs: Readings) -> Bool {
        lhs.providers.count == rhs.providers.count
            && zip(lhs.providers, rhs.providers).allSatisfy { $0.isEqual(to: $1) }
    }

    func shifted(by offset: TimeInterval) -> Readings {
        Readings(providers.map { $0.shifted(by: offset) })
    }
}

extension Readings: Decodable {
    /// Every built-in provider, each reading its own keys from the same
    /// object. Readings come from formats that can change without notice: a
    /// missing, renamed or mistyped field drops only the row it feeds (which
    /// then shows "—"); it never fails the whole readings file.
    public init(from decoder: any Decoder) throws {
        self.init(BuiltInProviders.all.compactMap { try? $0.init(from: decoder) })
    }
}

/// One limit window as a source reports it.
public struct LimitReading: Decodable, Equatable, Sendable {
    /// Percent of the window used, 0–100.
    public var usedPercent: Double
    public var resetsAt: Date

    public init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

extension LimitReading {
    func shifted(by offset: TimeInterval) -> LimitReading {
        LimitReading(usedPercent: usedPercent, resetsAt: resetsAt + offset)
    }
}

/// Decodes a `T`, or nil when that element is malformed, so one bad array
/// element doesn't sink its siblings.
struct Lenient<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
