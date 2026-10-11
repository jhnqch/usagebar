import Foundation
import Observation
import UsageCore

/// Holds the readings and the current snapshot. Lives on the main actor so
/// every UI state change happens there.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot
    @ObservationIgnored var onChange: ((UsageSnapshot) -> Void)?
    @ObservationIgnored private let readings: Readings
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(readings: Readings) {
        self.readings = readings
        snapshot = UsageEngine.snapshot(from: readings, now: Date(), timeZone: .current)
    }

    /// Recomputes the snapshot against the current clock.
    func refresh() {
        snapshot = UsageEngine.snapshot(from: readings, now: Date(), timeZone: .current)
        onChange?(snapshot)
    }

    /// Keeps countdowns and "Updated N min ago" current.
    func startTicking(every interval: Duration = .seconds(30)) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.refresh()
            }
        }
    }
}

/// Sample readings bundled with the app until live sources land: the
/// recorded sample, shifted so it reads as fresh at launch.
enum SampleReadings {
    static func load(now: Date = Date()) -> Readings {
        guard
            let url = Bundle.main.url(forResource: "sample", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let fixture = try? Fixture.decode(data)
        else { return Readings() }
        return fixture.readings(rebasedTo: now)
    }
}
