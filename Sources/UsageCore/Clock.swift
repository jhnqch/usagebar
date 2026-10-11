import Foundation

/// Time text relative to a fixed "now" in a given time zone.
struct Clock {
    var now: Date
    var timeZone: TimeZone

    private static let day: TimeInterval = 24 * 60 * 60

    /// Longest countdown shown: "99d 23h". Real windows reset within a week;
    /// the cap keeps an absurd reset time from overflowing `Int`.
    private static let maxCountdownMinutes = 100 * 1440 - 1

    /// "2d 16h", "1h 05m" or "45m", rounded up to the next minute so it never
    /// promises a reset sooner than it comes.
    func countdown(to end: Date) -> String {
        let raw = (end.timeIntervalSince(now) / 60).rounded(.up)
        let minutes = Int(min(max(raw, 0), Double(Self.maxCountdownMinutes)))
        switch minutes {
        case 1440...: return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
        case 60...: return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        default: return "\(max(minutes, 1))m"
        }
    }

    /// "Resets in 2h 18m (4:58 PM)" within a day, "Resets Tue 7:00 AM" beyond,
    /// "Reset at 2:00 PM" once passed. (A maxed window's pace line says
    /// "Limit reached".)
    func resetText(_ resetsAt: Date) -> String {
        let distance = resetsAt.timeIntervalSince(now)
        if distance <= 0 {
            return -distance < Self.day ? "Reset at \(format(resetsAt, "h:mm a"))" : "Reset \(format(resetsAt, "EEE h:mm a"))"
        }
        return distance < Self.day
            ? "Resets in \(countdown(to: resetsAt)) (\(format(resetsAt, "h:mm a")))"
            : "Resets \(format(resetsAt, "EEE h:mm a"))"
    }

    /// "Updated just now", "Updated 3 min ago", "Updated at 11:05 AM" (today),
    /// "Updated Thu 9:30 AM" (earlier).
    func updatedText(_ capturedAt: Date) -> String {
        let age = now.timeIntervalSince(capturedAt)
        if age < 60 { return "Updated just now" }
        if age < 3600 { return "Updated \(Int(age / 60)) min ago" }
        if calendar.isDate(capturedAt, inSameDayAs: now) {
            return "Updated at \(format(capturedAt, "h:mm a"))"
        }
        return "Updated \(format(capturedAt, "EEE h:mm a"))"
    }

    /// A rough time and the time it stands for: "4:30 PM", to the nearest 5
    /// minutes, when that's today; "Sun 5 PM", to the nearest hour, on
    /// another day. Rounds on the local clock, so a time zone off the hour
    /// still lands on :00 or :05.
    func approximately(_ date: Date) -> (date: Date, text: String) {
        guard let hour = calendar.dateInterval(of: .hour, for: date) else { return (date, format(date, "EEE h:mm a")) }
        let minutes = date.timeIntervalSince(hour.start) / 60
        let nearestFive = hour.start + (minutes / 5).rounded() * 5 * 60
        if calendar.isDate(nearestFive, inSameDayAs: now) {
            return (nearestFive, format(nearestFive, "h:mm a"))
        }
        let nearestHour = minutes < 30 ? hour.start : hour.end
        return (nearestHour, format(nearestHour, "EEE h a"))
    }

    /// "Tue 7 AM", or "Tue 7:30 AM" off the hour.
    func dayAndHour(_ date: Date) -> String {
        let minute = calendar.component(.minute, from: date)
        return format(date, minute == 0 ? "EEE h a" : "EEE h:mm a")
    }

    /// "Wed Oct 7".
    func dayAndDate(_ date: Date) -> String {
        format(date, "EEE MMM d")
    }

    /// "Wed".
    func weekday(_ date: Date) -> String {
        format(date, "EEE")
    }

    /// A Gregorian calendar in this time zone.
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
