import Foundation

/// The UTC Gregorian calendar that key providers' days, weeks (from
/// Monday) and billing months follow.
enum UTC {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Midnight UTC on the first 1st after `date`: when a monthly window
    /// resets.
    static func nextMonthStart(after date: Date) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(day: 1, hour: 0, minute: 0, second: 0), matchingPolicy: .strict)
    }
}

extension Date {
    /// An ISO 8601 time, with or without fractional seconds, as logs and
    /// APIs write them: "2026-10-09T22:20:44.544Z", "2026-11-01T00:00:00Z".
    init?(iso8601 text: String) {
        guard let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601)) else { return nil }
        self = date
    }
}
