import Foundation

/// A sample-readings file: readings plus the clock and time zone they were
/// recorded against. Snapshot mode renders it at `now`; the app rebases it to
/// the current time.
public struct Fixture: Equatable, Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var readings: Readings

    /// The readings shifted so they sit relative to `newNow` exactly as they
    /// sat relative to `now` when recorded. Lets the app show a sample that
    /// stays fresh instead of one whose windows reset long ago.
    public func readings(rebasedTo newNow: Date) -> Readings {
        readings.shifted(by: newNow.timeIntervalSince(now))
    }

    public static func decode(_ data: Data) throws -> Fixture {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(Raw.self, from: data)
        return Fixture(
            now: raw.now,
            timeZone: raw.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current,
            readings: raw.readings
        )
    }

    private struct Raw: Decodable {
        var now: Date
        var timeZone: String?
        var readings: Readings
    }
}
