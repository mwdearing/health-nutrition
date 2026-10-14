import Foundation

/// The seven local days ending today, with how many entries each one holds, for the Insights screen.
///
/// Counts only: nothing here is estimated, and a day with no entries is shown as empty, not as zero intake.
public struct InsightsWeek: Equatable {
    public struct Day: Equatable, Identifiable {
        public let id: Date
        /// "Mon", "Tue" in the locale, or the one-letter form a narrow bar label wants.
        public let label: String
        public let entryCount: Int
    }

    public static let length = 7

    public let days: [Day]
    public var loggedDays: Int { days.filter { $0.entryCount > 0 }.count }
    public var entryCount: Int { days.reduce(0) { $0 + $1.entryCount } }
    public var emptyDays: Int { days.count - loggedDays }
    public var hasAnyEntry: Bool { entryCount > 0 }

    /// "5 of 7 days logged".
    public var headline: String { "\(loggedDays) of \(days.count) days logged" }
    /// "12 entries", "1 entry".
    public var entriesText: String { entryCount == 1 ? "1 entry" : "\(entryCount) entries" }
    /// "2 days with no entries", "1 day with no entries".
    public var emptyDaysText: String {
        emptyDays == 1 ? "1 day with no entries" : "\(emptyDays) days with no entries"
    }
    /// The fraction of the tallest day, 0 through 1, for drawing a bar. An empty week draws nothing.
    public func barFraction(for day: Day) -> Double {
        let tallest = days.map(\.entryCount).max() ?? 0
        guard tallest > 0 else { return 0 }
        return Double(day.entryCount) / Double(tallest)
    }

    /// - Parameters:
    ///   - occurredAt: when each entry happened. Entries dated after `now` have not happened and are left out.
    ///   - now: the reference instant; the last day is the local day containing it.
    ///   - zone: the zone whose days are counted.
    public static func make(
        occurredAt: [Date], now: Date, zone: TimeZone, locale: Locale = .current
    ) -> InsightsWeek {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        var days: [Day] = []
        for offset in stride(from: length - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                let end = calendar.date(byAdding: .day, value: 1, to: start)
            else { continue }
            let count = occurredAt.filter { $0 >= start && $0 < end && $0 <= now }.count
            days.append(Day(id: start, label: formatter.string(from: start), entryCount: count))
        }
        return InsightsWeek(days: days)
    }
}
