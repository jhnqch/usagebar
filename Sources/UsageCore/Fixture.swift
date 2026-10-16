import Foundation

/// A sample-readings file: readings plus the clock and time zone they were
/// recorded against. Snapshot mode renders it at `now`; the app rebases it to
/// the current time.
public struct Fixture: Equatable, Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var readings: Readings
    /// Which providers are on and in the menu bar, as the Providers menu
    /// would set them; nil for every provider on and in the menu bar.
    public var selection: ProviderSelection? = nil
    /// The Alerts settings, as the Providers menu would set them; the
    /// defaults when the file doesn't say or can't be read.
    public var alertSettings = AlertSettings()

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
            readings: raw.readings,
            selection: raw.providers?.value.map { ProviderSelection(enabled: $0.enabled, menuBar: Set($0.menuBar ?? $0.enabled)) },
            alertSettings: raw.alerts?.value.map {
                AlertSettings(threshold: $0.threshold ?? AlertSettings.defaultThreshold, limitReached: $0.limitReached ?? true,
                              limitReset: $0.limitReset ?? true, providers: $0.providers ?? [:])
            } ?? AlertSettings()
        )
    }

    private struct Raw: Decodable {
        var now: Date
        var timeZone: String?
        var readings: Readings
        var providers: Lenient<Providers>?
        var alerts: Lenient<Alerts>?
    }

    private struct Alerts: Decodable {
        var threshold: Int?
        var limitReached: Bool?
        var limitReset: Bool?
        /// "Alerts" switches by provider id.
        var providers: [String: Bool]?
    }

    private struct Providers: Decodable {
        var enabled: [String]
        /// Defaults to every provider that's on.
        var menuBar: [String]?
    }
}
