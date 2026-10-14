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
    /// The journal entry a Taken tap recorded for this time, when it was marked that way. Nil for a time
    /// an entry logged elsewhere filled, or one not taken: only a recorded Taken can be undone from here.
    public let recordedEntryID: String?

    public init(time: ReminderTime, state: SupplementSlotState, recordedEntryID: String? = nil) {
        self.time = time
        self.state = state
        self.recordedEntryID = recordedEntryID
    }
}

/// The time a Taken tap was for: the item, the local day and the time of day. Kept per journal entry, so
/// the list shows the time the person said rather than one it guessed. Only today's marks are kept.
public struct SupplementTakenMark: Codable, Equatable, Sendable {
    public let favoriteID: String
    /// `yyyy-MM-dd`, the day the entry was logged for.
    public let dayKey: String
    /// "08:00", the stored form of the time.
    let time: String
    /// When the entry was logged by the tap. An entry whose time was corrected since (in the Journal) no
    /// longer stands for the tap, so its mark is dropped and it fills an open time like any other entry.
    public let loggedAt: Date

    public init(favoriteID: String, dayKey: String, time: ReminderTime, loggedAt: Date) {
        self.favoriteID = favoriteID
        self.dayKey = dayKey
        self.time = time.storedText
        self.loggedAt = loggedAt
    }

    /// Whether the entry still has the time the tap logged it at. A second's slack covers how a stored
    /// date is rounded; a correction in the Journal moves it by at least a minute.
    func matches(occurredAt: Date) -> Bool {
        abs(occurredAt.timeIntervalSince(loggedAt)) < 1
    }

    /// The time of day, or nil for a stored value that does not read as one.
    public var timeOfDay: ReminderTime? { ReminderTime(storedText: time) }
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
        guard let zone = TimeZone(identifier: zoneIdentifier),
              let key = IntakeCopier.dayKey(now, zoneIdentifier: zoneIdentifier)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return nil }
        self.dayKey = key
        self.weekday = weekday
        self.minuteOfDay = hour * 60 + minute
    }
}

/// How today's entries of one item map onto its times.
enum SupplementStackDay {
    /// Today's times for one schedule, earliest first, and where each stands.
    ///
    /// A time a Taken tap recorded is marked taken: `recordedMinutes` are those times, as minutes since
    /// midnight. Entries with no recorded time (logged from the Library, say) then fill the times still
    /// open, earliest first; `unrecordedCount` is how many there are. A recorded time the schedule no longer
    /// has counts as unrecorded. What is left over marks nothing. A time nothing marks reads "not logged"
    /// once it has passed and "later" before.
    static func slots(
        for schedule: SupplementSchedule, recordedMinutes: [Int], unrecordedCount: Int, minuteOfDay: Int
    ) -> [SupplementSlot] {
        slots(
            for: schedule, recorded: recordedMinutes.map { (minute: $0, entryID: String?.none) },
            unrecordedCount: unrecordedCount, minuteOfDay: minuteOfDay)
    }

    /// The same, with the entry each recorded time came from, so a time marked by a Taken tap can name
    /// the entry to undo.
    static func slots(
        for schedule: SupplementSchedule, recorded: [(minute: Int, entryID: String?)], unrecordedCount: Int,
        minuteOfDay: Int
    ) -> [SupplementSlot] {
        let minutes = schedule.times.map(SupplementSchedule.minuteOfDay)
        var taken = Array(repeating: false, count: minutes.count)
        var entryIDs = [String?](repeating: nil, count: minutes.count)
        var unrecorded = unrecordedCount
        for mark in recorded {
            if let index = minutes.firstIndex(of: mark.minute), !taken[index] {
                taken[index] = true
                entryIDs[index] = mark.entryID
            } else {
                unrecorded += 1
            }
        }
        for index in minutes.indices where !taken[index] && unrecorded > 0 {
            taken[index] = true
            unrecorded -= 1
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
            return SupplementSlot(time: schedule.times[index], state: state, recordedEntryID: entryIDs[index])
        }
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
    /// The time each Taken tap was for, by journal entry id.
    func takenMarks() -> [String: SupplementTakenMark]
    /// Replaces every mark.
    func saveTakenMarks(_ marks: [String: SupplementTakenMark]) throws
}

/// Keeps the schedules as one JSON object under one key in the app's defaults domain, the way the custom
/// reminders keep theirs. The favorites store is left alone: its file has no versioned schema, and a new
/// column there would be the first change that file's rows have ever had to migrate through.
///
/// An entry that does not read as a schedule is left out rather than failing the whole list, and a value
/// that is not a JSON object of schedules reads as an empty list.
///
/// The times Taken taps were for are kept the same way under a second key.
///
/// Erase all data removes both keys: the schedules and the marks say what a person takes and when, so they
/// are erased with the favorites they belong to.
public final class UserDefaultsSupplementStackStore: SupplementStackStoring, JournalErasing, @unchecked Sendable {
    public static let key = "supplementStack.schedules"
    public static let takenKey = "supplementStack.taken"
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

    public func takenMarks() -> [String: SupplementTakenMark] {
        guard let data = defaults.data(forKey: Self.takenKey),
              let stored = try? JSONDecoder().decode([String: LenientMark].self, from: data)
        else { return [:] }
        return stored.compactMapValues(\.mark)
    }

    public func saveTakenMarks(_ marks: [String: SupplementTakenMark]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(marks), forKey: Self.takenKey)
    }

    public func eraseAll() throws {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.takenKey)
    }
}

/// One stored mark that may not read: nil rather than a thrown error, so one damaged mark does not hide the
/// others. A mark whose time does not read as a time of day is dropped as well.
private struct LenientMark: Decodable {
    let mark: SupplementTakenMark?

    init(from decoder: Decoder) throws {
        let decoded = try? SupplementTakenMark(from: decoder)
        mark = decoded?.timeOfDay == nil ? nil : decoded
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
