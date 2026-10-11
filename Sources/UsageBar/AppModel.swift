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
    @ObservationIgnored private var readings: Readings
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(readings: Readings) {
        self.readings = readings
        snapshot = UsageEngine.snapshot(from: readings, now: Date(), timeZone: .current)
    }

    /// Changes the readings and, if they changed, recomputes the snapshot.
    func update(_ change: (inout Readings) -> Void) {
        var updated = readings
        change(&updated)
        guard updated != readings else { return }
        readings = updated
        refresh()
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

/// What the app bundles: Claude's plan for the badge, from the recorded
/// sample. Neither Claude source reports the plan; every limit is live.
enum SampleReadings {
    static func load() -> Readings {
        guard
            let url = Bundle.main.url(forResource: "sample", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let fixture = try? Fixture.decode(data)
        else { return Readings() }
        return Readings(claudePlan: fixture.readings.claudePlan)
    }
}
