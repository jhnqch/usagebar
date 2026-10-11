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

/// The Claude readings bundled with the app until the usage endpoint lands
/// (ticket #5): the plan and the Fable window from the recorded sample,
/// shifted so they read as fresh at launch. Claude's 5-hour and weekly
/// windows are live from the status line and Codex is live, so the sample's
/// numbers for those are dropped. A sample has no real capture time.
enum SampleReadings {
    static func load(now: Date = Date()) -> Readings {
        guard
            let url = Bundle.main.url(forResource: "sample", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let fixture = try? Fixture.decode(data)
        else { return Readings() }
        let sample = fixture.readings(rebasedTo: now).claude
        return Readings(claude: ClaudeLimits(plan: sample?.plan, capturedAt: nil, sevenDayFable: sample?.sevenDayFable))
    }
}
