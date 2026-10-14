import Foundation
import NutritionDomain
import NutritionJournal

/// When one item on the supplement list is taken: one or more times of day, on chosen days of the week.
///
/// A schedule says only when the person means to take something. It states no amount: the amount is the
/// favorite's, copied from what was logged, so the list never suggests or changes how much is taken.
public struct SupplementSchedule: Equatable, Sendable {
    /// The most times one item can have in a day.
    public static let maxTimesPerDay = 6
    /// Every day of the week, numbered the way `Calendar` numbers weekdays: 1 is Sunday, 7 is Saturday.
    public static let everyDay: Set<Int> = Set(1...7)

    /// Distinct, earliest first.
    public let times: [ReminderTime]
    /// `Calendar` weekday numbers, 1 (Sunday) to 7 (Saturday). Never empty.
    public let weekdays: Set<Int>

    /// Nil for no times, more than `maxTimesPerDay` times, the same time twice, no days, or a day outside
    /// 1 to 7: each is a list the screen cannot show as a plan for the day.
    public init?(times: [ReminderTime], weekdays: Set<Int> = SupplementSchedule.everyDay) {
        let minutes = times.map(Self.minuteOfDay)
        guard !times.isEmpty, times.count <= Self.maxTimesPerDay, Set(minutes).count == minutes.count,
              !weekdays.isEmpty, weekdays.isSubset(of: Self.everyDay)
        else { return nil }
        self.times = times.sorted { Self.minuteOfDay($0) < Self.minuteOfDay($1) }
        self.weekdays = weekdays
    }

    /// The schedule a newly added item starts with: once a day at 08:00, every day.
    public static let standard = SupplementSchedule(times: [ReminderTime(hour: 8, minute: 0)])!

    public var isEveryDay: Bool { weekdays == Self.everyDay }

    static func minuteOfDay(_ time: ReminderTime) -> Int {
        time.hour * 60 + time.minute
    }
}

/// Stored as `{"times": ["08:00", "20:00"], "weekdays": [1, 2, 3, 4, 5, 6, 7]}`. Reading applies the same
/// rules as `init?(times:weekdays:)`, so a value edited or damaged outside the app cannot come back as a
/// schedule the screen could not have saved.
extension SupplementSchedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case times
        case weekdays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let texts = try container.decode([String].self, forKey: .times)
        let days = try container.decode([Int].self, forKey: .weekdays)
        var parsed: [ReminderTime] = []
        for text in texts {
            guard let time = ReminderTime(storedText: text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .times, in: container, debugDescription: "\(text) is not a time of day")
            }
            parsed.append(time)
        }
        guard Set(days).count == days.count, let schedule = SupplementSchedule(times: parsed, weekdays: Set(days))
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .weekdays, in: container, debugDescription: "the times and days are not a schedule")
        }
        self = schedule
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(times.map(\.storedText), forKey: .times)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
    }
}

/// Where one of today's times stands.
public enum SupplementSlotState: Equatable, Sendable {
    /// An entry of this item logged today covers this time.
    case taken
    /// The time has not come yet.
    case later
    /// The time has passed and no entry covers it. The screen says "Not logged": it reports what the
    /// journal holds and passes no judgment on it.
    case notLogged
}

/// One of today's times for one item, and where it stands.
public struct SupplementSlot: Equatable, Sendable {
    public let time: ReminderTime
    public let state: SupplementSlotState

    public init(time: ReminderTime, state: SupplementSlotState) {
        self.time = time
        self.state = state
    }
}

/// The present as the list reads it: the local day, weekday and minute in one time zone.
///
/// Read from the calendar's own components rather than from an offset, so a day that skips or repeats
/// an hour for daylight saving still names the wall-clock minute the person sees.
struct SupplementStackClock: Equatable {
    /// `yyyy-MM-dd`, the same key the Journal groups entries by.
    let dayKey: String
    let weekday: Int
    let minuteOfDay: Int

    /// Nil when `zoneIdentifier` names no time zone.
    init?(now: Date, zoneIdentifier: String) {
        guard let local = SupplementStackDay.local(now, zoneIdentifier: zoneIdentifier) else { return nil }
        self.dayKey = local.dayKey
        self.weekday = local.weekday
        self.minuteOfDay = local.minuteOfDay
    }
}

/// How today's entries of one item map onto its times.
enum SupplementStackDay {
    /// How long before a time an entry can be and still count for it: a dose taken a little early.
    static let earlyWindowMinutes = 60

    /// Today's times for one schedule, earliest first, and where each stands. `loggedMinutes` are when
    /// today's entries were logged, in minutes since each entry's own local midnight.
    ///
    /// Each entry, in time order, belongs to one time: the latest time at or before it (a dose taken on
    /// time or late), unless the next time is at most an hour away and nearer (a dose taken early). An
    /// entry before every time belongs to the first only within that hour: one logged just after midnight
    /// is more likely the night before's than this morning's, so it marks nothing. An entry whose time is
    /// already marked is an extra one and marks nothing, so a second tap never marks a time that was
    /// missed: a missed morning stays "Not logged" whatever is logged in the evening. A time no entry
    /// marks reads "not logged" once it has passed and "later" before.
    static func slots(for schedule: SupplementSchedule, loggedMinutes: [Int], minuteOfDay: Int) -> [SupplementSlot] {
        let minutes = schedule.times.map(SupplementSchedule.minuteOfDay)
        var taken = Array(repeating: false, count: minutes.count)
        for logged in loggedMinutes.sorted() {
            if let index = owner(of: logged, among: minutes) { taken[index] = true }
        }
        return schedule.times.indices.map { index in
            let state: SupplementSlotState
            if taken[index] {
                state = .taken
            } else if minutes[index] <= minuteOfDay {
                state = .notLogged
            } else {
                state = .later
            }
            return SupplementSlot(time: schedule.times[index], state: state)
        }
    }

    /// The index of the time an entry logged at `logged` belongs to, by the rule `slots` states. `minutes`
    /// are sorted and distinct, as a schedule's times are.
    static func owner(of logged: Int, among minutes: [Int]) -> Int? {
        let previous = minutes.lastIndex { $0 <= logged }
        if let next = minutes.firstIndex(where: { $0 > logged }), minutes[next] - logged <= earlyWindowMinutes,
           previous.map({ minutes[next] - logged < logged - minutes[$0] }) ?? true
        {
            return next
        }
        return previous
    }

    /// The local day key (`yyyy-MM-dd`, the copier's, so it matches the Journal's day rule), weekday and
    /// minute since midnight of `date` in `zoneIdentifier`. Nil for a zone identifier that names no zone.
    static func local(_ date: Date, zoneIdentifier: String) -> (dayKey: String, weekday: Int, minuteOfDay: Int)? {
        guard let dayKey = IntakeCopier.dayKey(date, zoneIdentifier: zoneIdentifier),
              let clock = wallClock(date, zoneIdentifier: zoneIdentifier)
        else { return nil }
        return (dayKey, clock.weekday, clock.minuteOfDay)
    }

    /// The weekday and minute since midnight of `date` in `zoneIdentifier`, from the calendar's components,
    /// so a day that skips or repeats an hour still names the wall clock the person sees.
    static func wallClock(_ date: Date, zoneIdentifier: String) -> (weekday: Int, minuteOfDay: Int)? {
        guard let zone = TimeZone(identifier: zoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return nil }
        return (weekday, hour * 60 + minute)
    }

    /// What tells an entry of an item from an entry of anything else: the product snapshot when there is
    /// one, otherwise the category and the component names. The meal is left out on purpose: a supplement
    /// taken with breakfast or with no meal named is the same supplement taken.
    static func matchKey(category: String, snapshotID: String?, names: [String]) -> String {
        RecentItemsProvider.identityKey(category: category, snapshotID: snapshotID, names: names, meal: nil)
    }
}

/// The words the list shows. English only, like the rest of the app.
public enum SupplementStackText {
    /// Short weekday names, indexed by `Calendar` weekday number minus one.
    static let shortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// Full weekday names, indexed the same way.
    public static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    /// The order the days are offered in: Monday first.
    public static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    /// A time of day in the person's own clock style, for example "8:00 AM" or "08:00".
    public static func time(_ time: ReminderTime, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: time.hour, minute: time.minute))
            ?? Date(timeIntervalSinceReferenceDate: TimeInterval(SupplementSchedule.minuteOfDay(time) * 60))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "Every day at 8:00 AM and 8:00 PM", or "Mon, Wed, Fri at 8:00 AM".
    public static func summary(_ schedule: SupplementSchedule, locale: Locale = .current) -> String {
        let days = schedule.isEveryDay
            ? "Every day"
            : weekdayOrder.filter { schedule.weekdays.contains($0) }.map { shortWeekdays[$0 - 1] }
                .joined(separator: ", ")
        let times = schedule.times.map { time($0, locale: locale) }
        let joined = times.count > 1
            ? times.dropLast().joined(separator: ", ") + " and " + (times.last ?? "")
            : times.first ?? ""
        return "\(days) at \(joined)"
    }

    /// "8:00 AM · Taken", "8:00 PM · Later today" or "8:00 AM · Not logged".
    public static func slot(_ slot: SupplementSlot, locale: Locale = .current) -> String {
        let state: String
        switch slot.state {
        case .taken: state = "Taken"
        case .later: state = "Later today"
        case .notLogged: state = "Not logged"
        }
        return "\(time(slot.time, locale: locale)) · \(state)"
    }
}

/// Where the supplement list keeps its schedules: one schedule per favorite id.
public protocol SupplementStackStoring: AnyObject {
    /// Every readable schedule, by favorite id.
    func schedules() -> [String: SupplementSchedule]
    /// Replaces the whole list.
    func save(_ schedules: [String: SupplementSchedule]) throws
}

/// Keeps the schedules as one JSON object under one key in the app's defaults domain, the way the custom
/// reminders keep theirs. The favorites store is left alone: its file has no versioned schema, and a new
/// column there would be the first change that file's rows have ever had to migrate through.
///
/// An entry that does not read as a schedule is left out rather than failing the whole list, and a value
/// that is not a JSON object of schedules reads as an empty list.
///
/// Erase all data removes the key: the schedules say what a person takes and when, so they are erased
/// with the favorites they belong to.
public final class UserDefaultsSupplementStackStore: SupplementStackStoring, JournalErasing, @unchecked Sendable {
    public static let key = "supplementStack.schedules"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func schedules() -> [String: SupplementSchedule] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([String: LenientSchedule].self, from: data)
        else { return [:] }
        return stored.compactMapValues(\.schedule)
    }

    public func save(_ schedules: [String: SupplementSchedule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(schedules), forKey: Self.key)
    }

    public func eraseAll() throws {
        defaults.removeObject(forKey: Self.key)
    }
}

/// One stored schedule that may not read: nil rather than a thrown error, so one damaged entry does not
/// hide every other item on the list.
private struct LenientSchedule: Decodable {
    let schedule: SupplementSchedule?

    init(from decoder: Decoder) throws {
        schedule = try? SupplementSchedule(from: decoder)
    }
}
