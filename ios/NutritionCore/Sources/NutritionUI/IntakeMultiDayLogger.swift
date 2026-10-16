import Foundation
import NutritionJournal

/// Why a chosen day got no entry.
public enum MultiDaySkipReason: Equatable, Sendable {
    /// The entry's own day: it is already logged there.
    case entryDay
    /// Today, but the entry's time of day has not come yet.
    case laterToday
    /// A day after today.
    case future
    /// Not a date that exists, such as February 31.
    case notADate
}

/// One chosen day that got no entry, as yyyy-MM-dd, and why.
public struct MultiDaySkippedDay: Equatable, Sendable {
    public let day: String
    public let reason: MultiDaySkipReason

    public init(day: String, reason: MultiDaySkipReason) {
        self.day = day
        self.reason = reason
    }
}

/// What logging an entry on other days wrote: the new entries, and the chosen days it left out.
public struct IntakeMultiDayResult: Equatable, Sendable {
    public let createdIDs: [String]
    /// Chosen days that got no entry, in day order, each with its reason.
    public let skipped: [MultiDaySkippedDay]

    public init(createdIDs: [String], skipped: [MultiDaySkippedDay]) {
        self.createdIDs = createdIDs
        self.skipped = skipped
    }

    /// The skipped days alone, as yyyy-MM-dd.
    public var skippedDays: [String] { skipped.map(\.day) }
}

/// What Log on other days did, for the screen that ran it.
public enum MultiDayLogOutcome: Equatable {
    /// At least one new entry was logged.
    case logged(IntakeMultiDayResult)
    /// Nothing was logged; the reason is stated by the screen's model.
    case nothingLogged
    /// A write failed and these new entries could not be removed again.
    case leftEntries([String])
}

/// Why nothing was logged on the chosen days.
public enum IntakeMultiDayError: Error, Equatable, Sendable {
    /// The entry is deleted or its current revision cannot be read.
    case entryUnavailable
    /// The entry's stored time zone names no zone, so its time of day has no meaning on another day.
    case unreadableTimeZone
    /// More than `IntakeMultiDayLogger.maximumDays` days, or a day that is not a yyyy-MM-dd date.
    case invalidDays
    /// A write failed and the entries already written could not all be deleted again. They are named here.
    case partial(remainingIDs: [String])
}

/// Logs one entry again on other days: a new entry on each chosen day, at the same time of day in the
/// entry's own time zone, with the same amounts, meal and product. The entry itself is untouched.
///
/// Nobody has eaten anything in the future, so a day whose time has not come yet is skipped, as is the
/// entry's own day. A failed write leaves no new entry behind: the ones already written are deleted again.
public struct IntakeMultiDayLogger {
    public static let maximumDays = 14
    private let store: JournalStore
    private let makeID: () -> String

    public init(store: JournalStore, makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store
        self.makeID = makeID
    }

    public func log(intakeID: String, onDays dayKeys: Set<String>, now: Date) throws -> IntakeMultiDayResult {
        guard !dayKeys.isEmpty, dayKeys.count <= Self.maximumDays else { throw IntakeMultiDayError.invalidDays }
        let days = try dayKeys.sorted().map { key -> (key: String, parts: DateComponents) in
            guard let parts = Self.dayParts(key) else { throw IntakeMultiDayError.invalidDays }
            return (key, parts)
        }
        // A revision that cannot be read leaves nothing to repeat, as a deleted entry does.
        guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }),
            let current = (try? store.revisions(of: intakeID))?.first(where: { $0.number == intake.currentRevision })
        else { throw IntakeMultiDayError.entryUnavailable }
        guard let zone = TimeZone(identifier: intake.timeZoneIdentifier),
            let ownDay = IntakeCopier.dayKey(intake.occurredAt, zoneIdentifier: intake.timeZoneIdentifier)
        else { throw IntakeMultiDayError.unreadableTimeZone }
        var product: ProductDefinition?
        if let snapshotID = current.productSnapshotID {
            guard let found = try store.product(snapshotID: snapshotID) else { throw IntakeRepeatError.productUnavailable }
            product = found
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let time = calendar.dateComponents([.hour, .minute, .second], from: intake.occurredAt)

        let today = IntakeCopier.dayKey(now, zoneIdentifier: intake.timeZoneIdentifier)
        // Copies of an entry kept out of Library stay out of Library too.
        let keepsOut = try ((store as? JournalLibraryExclusions)?.intakeIDsNotSavedToLibrary() ?? []).contains(intake.id)
        var created: [String] = []
        var skipped: [MultiDaySkippedDay] = []
        // The units the entry was logged in are carried to each copy, as repeating it does.
        let loggedUnits = LoggedUnitIndex.load(from: store)[intake.id] ?? [:]
        for day in days {
            guard day.key != ownDay else {
                skipped.append(MultiDaySkippedDay(day: day.key, reason: .entryDay))
                continue
            }
            var parts = day.parts
            parts.hour = time.hour
            parts.minute = time.minute
            parts.second = time.second
            // A time a clock change skips on that day moves to the next valid time, as the calendar reads it.
            // The result must still fall on the chosen day, which also refuses a date such as February 31.
            guard let occurredAt = calendar.date(from: parts),
                IntakeCopier.dayKey(occurredAt, zoneIdentifier: intake.timeZoneIdentifier) == day.key
            else {
                skipped.append(MultiDaySkippedDay(day: day.key, reason: .notADate))
                continue
            }
            guard occurredAt <= now else {
                skipped.append(MultiDaySkippedDay(day: day.key, reason: day.key == today ? .laterToday : .future))
                continue
            }
            let copy = Intake(
                id: makeID(), category: intake.category, occurredAt: occurredAt,
                timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal)
            do {
                if keepsOut { try (store as? JournalLibraryExclusions)?.keepOutOfLibrary(intakeID: copy.id) }
                if let units = store as? JournalLoggedUnits {
                    for component in current.components where component.unit == .mL {
                        guard let loggedUnit = loggedUnits[component.componentID] else { continue }
                        try units.recordLoggedUnit(JournalLoggedUnit(
                            intakeID: copy.id, componentID: component.componentID, unit: loggedUnit))
                    }
                }
                try store.create(copy, components: current.components, product: product, now: now)
                created.append(copy.id)
            } catch let writeError {
                var remaining: [String] = []
                for id in created.reversed() {
                    do {
                        try store.delete(intakeID: id, now: now)
                    } catch JournalError.intakeDeleted(_) {
                        continue
                    } catch {
                        remaining.append(id)
                    }
                }
                guard remaining.isEmpty else { throw IntakeMultiDayError.partial(remainingIDs: Array(remaining.reversed())) }
                throw writeError
            }
        }
        return IntakeMultiDayResult(createdIDs: created, skipped: skipped)
    }

    /// The year, month and day of a yyyy-MM-dd key, or nil for anything else.
    static func dayParts(_ key: String) -> DateComponents? {
        let fields = key.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
            let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// The yyyy-MM-dd key, in the Gregorian calendar, for a picked date's year, month and day. The picker
    /// states them in the calendar it shows (the components' own, else the device's), which need not be
    /// Gregorian: a Japanese or Buddhist year is read through that calendar first.
    public static func dayKey(_ parts: DateComponents) -> String? {
        guard parts.year != nil, parts.month != nil, parts.day != nil else { return nil }
        let calendar = parts.calendar ?? Calendar.current
        guard let date = calendar.date(from: parts) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = parts.timeZone ?? calendar.timeZone
        let day = gregorian.dateComponents([.year, .month, .day], from: date)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    }
}
