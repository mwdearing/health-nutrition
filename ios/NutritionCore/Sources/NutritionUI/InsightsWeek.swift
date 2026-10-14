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

    /// One entry as the Diary files it: when it happened and the zone it was logged in.
    public struct Entry: Equatable {
        public let occurredAt: Date
        public let timeZoneIdentifier: String

        public init(occurredAt: Date, timeZoneIdentifier: String) {
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
        }
    }

    /// - Parameters:
    ///   - entries: each entry with the zone it was logged in. An entry sits on the calendar day it has in
    ///     its own zone, which is how the Diary files it, so a trip across zones cannot move it to another day
    ///     here. Entries dated after `now` have not happened and are left out.
    ///   - now: the reference instant; the last day is today's date in `zone`.
    ///   - zone: the zone that says which date today is.
    public static func make(
        entries: [Entry], now: Date, zone: TimeZone, locale: Locale = .current
    ) -> InsightsWeek {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        var keyCounts: [Int: Int] = [:]
        for entry in entries where entry.occurredAt <= now {
            var own = Calendar(identifier: .gregorian)
            own.timeZone = TimeZone(identifier: entry.timeZoneIdentifier) ?? zone
            keyCounts[dayKey(own.dateComponents([.year, .month, .day], from: entry.occurredAt)), default: 0] += 1
        }
        var days: [Day] = []
        for offset in stride(from: length - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = dayKey(calendar.dateComponents([.year, .month, .day], from: start))
            days.append(Day(id: start, label: formatter.string(from: start), entryCount: keyCounts[key] ?? 0))
        }
        return InsightsWeek(days: days)
    }

    private static func dayKey(_ components: DateComponents) -> Int {
        (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }
}

/// What the Insights screen shows while the diary is read: not a summary until a read has finished, and
/// the read's failure instead of an empty week.
public enum InsightsLoadState: Equatable {
    case loading
    case failed(String)
    /// `skipped` is how many entries the diary could not read and left out, so the week is not shown as complete.
    case ready(InsightsWeek, skipped: Int)

    public static func resolve(
        errorMessage: String?, loadCount: Int, skippedCount: Int = 0, entries: [InsightsWeek.Entry], now: Date,
        zone: TimeZone, locale: Locale = .current
    ) -> InsightsLoadState {
        if let errorMessage { return .failed(errorMessage) }
        guard loadCount > 0 else { return .loading }
        return .ready(
            InsightsWeek.make(entries: entries, now: now, zone: zone, locale: locale), skipped: max(0, skippedCount))
    }
}
