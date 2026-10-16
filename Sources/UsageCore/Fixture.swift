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
    /// The update line and Updates menu to draw, in snapshot mode; nil
    /// when the file has no `update` section or it can't be read.
    public var update: Updater? = nil

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
            } ?? AlertSettings(),
            update: raw.update?.value.flatMap { $0.updater(at: raw.now) }
        )
    }

    private struct Raw: Decodable {
        var now: Date
        var timeZone: String?
        var readings: Readings
        var providers: Lenient<Providers>?
        var alerts: Lenient<Alerts>?
        var update: Lenient<Update>?
    }

    /// `"update": { "version": "v1.0.0", "repository": "acme/usagebar",
    /// "source": true, "latest": "v1.1.0", "lastCheck": "…",
    /// "state": "available" | "installing" | "failed", "step": "building",
    /// "failure": "The build failed.", "log": "~/…/update.log" }`.
    /// `source` says whether the build has a checkout to update.
    private struct Update: Decodable {
        var version: String?
        var repository: String
        var source: Bool?
        var latest: String
        var lastCheck: Date?
        var state: String?
        var step: UpdateStep?
        var failure: String?
        var log: String?

        func updater(at now: Date) -> Updater? {
            guard let version = SemanticVersion(latest) else { return nil }
            var updater = Updater(build: BuildInfo(
                version: self.version.flatMap { BuildVersion(describe: $0) }, repository: GitHubRepository(repository),
                sourcePath: source == true ? "/path/to/usagebar" : nil
            ))
            let checkedAt = lastCheck ?? now
            guard updater.startCheck(at: checkedAt) else { return nil }
            _ = updater.finishCheck(.release(Release(version: version, tag: latest,
                                                     page: URL(string: "https://github.com/\(repository)/releases/tag/\(latest)"))),
                                    at: checkedAt)
            if state == "installing" || state == "failed" {
                guard updater.startInstall() != nil else { return nil }
                updater.advance(step ?? .building)
            }
            if state == "failed" {
                updater.fail(UpdateFailure(message: failure ?? "The build failed.", logPath: log))
            }
            return updater
        }
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
