import Foundation

/// Time text relative to a fixed "now" in a given time zone.
struct Clock {
    var now: Date
    var timeZone: TimeZone

    private static let day: TimeInterval = 24 * 60 * 60

    /// "2d 16h", "1h 05m" or "45m", rounded up to the next minute so it never
    /// promises a reset sooner than it comes.
    func countdown(to end: Date) -> String {
        let minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up))
        switch minutes {
        case 1440...: return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
        case 60...: return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        default: return "\(max(minutes, 1))m"
        }
    }

    /// "Resets in 2h 18m (4:58 PM)" within a day, "Resets Tue 7:00 AM" beyond,
    /// "Reset at 2:00 PM" once passed. Maxed windows lead with "Limit reached".
    func resetText(_ resetsAt: Date, maxed: Bool) -> String {
        let distance = resetsAt.timeIntervalSince(now)
        if distance <= 0 {
            return -distance < Self.day ? "Reset at \(format(resetsAt, "h:mm a"))" : "Reset \(format(resetsAt, "EEE h:mm a"))"
        }
        let when = distance < Self.day
            ? "in \(countdown(to: resetsAt)) (\(format(resetsAt, "h:mm a")))"
            : format(resetsAt, "EEE h:mm a")
        return maxed ? "Limit reached · resets \(when)" : "Resets \(when)"
    }

    /// "Updated just now", "Updated 3 min ago", "Updated at 11:05 AM" (today),
    /// "Updated Thu 9:30 AM" (earlier).
    func updatedText(_ capturedAt: Date) -> String {
        let age = now.timeIntervalSince(capturedAt)
        if age < 60 { return "Updated just now" }
        if age < 3600 { return "Updated \(Int(age / 60)) min ago" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(capturedAt, inSameDayAs: now) {
            return "Updated at \(format(capturedAt, "h:mm a"))"
        }
        return "Updated \(format(capturedAt, "EEE h:mm a"))"
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
