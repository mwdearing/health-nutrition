import Foundation

/// The units a medication amount can be typed in: milligrams, micrograms, milliliters or units. Nothing here
/// says which unit a medication uses: the person picks one for each medication, and each dose is logged in
/// its medication's unit.
public enum MedicationUnit: String, CaseIterable, Sendable, Equatable {
    /// Milligrams.
    case mg
    /// Micrograms.
    case mcg
    /// Milliliters.
    case mL
    /// Units, as the person types them.
    case units
}

/// Why a medication or a dose is not usable as entered.
public enum MedicationError: Error, Sendable, Equatable {
    /// The name is empty or only whitespace.
    case nameEmpty
    /// The name starts or ends with whitespace (a space, a tab or a line break).
    case nameNotTrimmed
    /// The name holds a line break inside it.
    case nameHasLineBreak
    /// The name is longer than the limit.
    case nameTooLong
    /// The schedule is outside the days the log accepts.
    case scheduleOutOfRange
    /// The amount is not a number above zero.
    case amountNotPositive
    /// The amount is above the limit.
    case amountTooLarge
    /// The amount has more decimal places than the log stores.
    case amountTooPrecise
    /// The time zone identifier is empty or this device does not know it.
    case timeZoneUnknown
    /// The note is empty or only whitespace.
    case noteEmpty
    /// The note is longer than the limit.
    case noteTooLong
    /// The site is empty or only whitespace.
    case siteEmpty
    /// The site starts or ends with whitespace (a space, a tab or a line break).
    case siteNotTrimmed
    /// The site holds a line break inside it.
    case siteHasLineBreak
    /// The site is longer than the limit.
    case siteTooLong
}

/// A medication the person tracks, under a name they typed. Nothing here knows what the medication is.
///
/// A medication can be archived to set it aside without deleting the doses already logged.
public struct Medication: Sendable, Equatable {
    /// The maximum number of Characters in the name.
    public static let maximumNameLength = 60
    /// The days a schedule may repeat over: one to twenty-eight.
    public static let scheduleDayRange: ClosedRange<Int> = 1...28

    /// The identifier that doses refer to.
    public let id: UUID
    /// The name the person typed, as stored.
    public let name: String
    /// The unit the person chose for this medication.
    public let unit: MedicationUnit
    /// How many calendar days apart the doses are meant to be, when the person keeps a schedule.
    public let scheduleDays: Int?
    /// Whether the medication is archived. An archived medication keeps its doses, and its schedule reports
    /// nothing until it is unarchived.
    public let isArchived: Bool

    /// A medication with the given name and unit. Nothing is checked until `validate()` is called.
    public init(
        id: UUID = UUID(), name: String, unit: MedicationUnit, scheduleDays: Int? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.scheduleDays = scheduleDays
        self.isArchived = isArchived
    }

    /// Checks the name, then the schedule when there is one, in this order: the name must not be blank,
    /// must not start or end with whitespace, must not hold a line break, and must fit the length limit.
    /// A schedule must fall in `scheduleDayRange`.
    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw MedicationError.nameEmpty
        }
        if trimmed != name {
            throw MedicationError.nameNotTrimmed
        }
        if name.contains(where: { $0.isNewline }) {
            throw MedicationError.nameHasLineBreak
        }
        if name.count > Self.maximumNameLength {
            throw MedicationError.nameTooLong
        }
        if let scheduleDays, !Self.scheduleDayRange.contains(scheduleDays) {
            throw MedicationError.scheduleOutOfRange
        }
    }
}

/// One dose the person logged: when it was taken, in which time zone, and how much. The amount is the
/// number as typed; nothing here compares it with any range.
public struct MedicationDose: Sendable, Equatable {
    /// The largest amount a single dose may hold.
    public static let maximumAmount: Decimal = 1000
    /// The most decimal places an amount may have.
    public static let maximumFractionDigits = 3
    /// The maximum number of Characters in the note.
    public static let maximumNoteLength = 200
    /// The maximum number of Characters in the site.
    public static let maximumSiteLength = 40

    /// The identifier of this dose.
    public let id: UUID
    /// The medication this dose belongs to.
    public let medicationID: UUID
    /// The instant the dose was taken.
    public let takenAt: Date
    /// The IANA time zone identifier the dose was logged in. It decides which local day the dose is on.
    public let timeZoneIdentifier: String
    /// The amount taken, as typed.
    public let amount: Decimal
    /// The unit of the amount.
    public let unit: MedicationUnit
    /// The injection site the person typed, kept with the dose only. Nothing in the log reads it.
    public let site: String?
    /// An optional note the person wrote about the dose.
    public let note: String?

    /// A dose with the given fields. Nothing is checked until `validate()` is called.
    public init(
        id: UUID = UUID(), medicationID: UUID, takenAt: Date, timeZoneIdentifier: String, amount: Decimal,
        unit: MedicationUnit, site: String? = nil, note: String? = nil
    ) {
        self.id = id
        self.medicationID = medicationID
        self.takenAt = takenAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.amount = amount
        self.unit = unit
        self.site = site
        self.note = note
    }

    /// The local day the dose was taken on, in the dose's own time zone. Nil when the time zone is not
    /// one this device knows.
    public var day: CalendarDay? {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: takenAt)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }

    /// Checks the amount, then the time zone, then the site, then the note, in this order. The amount must be
    /// a number above zero and at most `maximumAmount`, with no more than `maximumFractionDigits` decimal
    /// places. The time zone must be one this device knows. A site, when present, must not be blank, must not
    /// start or end with whitespace, must not hold a line break, and must fit `maximumSiteLength`. A note, when
    /// present, must not be blank and must fit `maximumNoteLength`.
    public func validate() throws {
        if amount.isNaN || amount <= 0 {
            throw MedicationError.amountNotPositive
        }
        if amount > Self.maximumAmount {
            throw MedicationError.amountTooLarge
        }
        var rounded = Decimal()
        var original = amount
        NSDecimalRound(&rounded, &original, Self.maximumFractionDigits, .plain)
        if rounded != amount {
            throw MedicationError.amountTooPrecise
        }
        if timeZoneIdentifier.isEmpty || TimeZone(identifier: timeZoneIdentifier) == nil {
            throw MedicationError.timeZoneUnknown
        }
        if let site {
            if site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MedicationError.siteEmpty
            }
            if site.trimmingCharacters(in: .whitespacesAndNewlines) != site {
                throw MedicationError.siteNotTrimmed
            }
            if site.contains(where: { $0.isNewline }) {
                throw MedicationError.siteHasLineBreak
            }
            if site.count > Self.maximumSiteLength {
                throw MedicationError.siteTooLong
            }
        }
        if let note {
            if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MedicationError.noteEmpty
            }
            if note.count > Self.maximumNoteLength {
                throw MedicationError.noteTooLong
            }
        }
    }
}

/// Where a medication's schedule stands today.
public enum MedicationScheduleStatus: Sendable, Equatable {
    /// The medication has no schedule, or is archived, so there is nothing to be due.
    case notScheduled
    /// The medication has a schedule but no dose has been logged yet.
    case noDoseYet
    /// The next dose is on a later day than today; the day is given.
    case upcoming(CalendarDay)
    /// The next dose falls on today.
    case dueToday
    /// The next dose fell on an earlier day; `days` is the whole number of days since it was due.
    case overdue(days: Int)
}

/// Rules over medications and doses that need no storage: the last dose, the days since it, and the
/// schedule's next day. Everything here reports days; nothing advises.
public enum MedicationLog {
    /// The latest dose of the medication with this identifier. When two doses share an instant, the one
    /// whose identifier text sorts last is chosen. Nil when there are no such doses.
    public static func lastDose(of medicationID: UUID, in doses: [MedicationDose]) -> MedicationDose? {
        var latest: MedicationDose?
        for dose in doses where dose.medicationID == medicationID {
            guard let current = latest else {
                latest = dose
                continue
            }
            if dose.takenAt > current.takenAt
                || (dose.takenAt == current.takenAt && dose.id.uuidString > current.id.uuidString)
            {
                latest = dose
            }
        }
        return latest
    }

    /// The whole number of calendar days from the dose's local day to `today`; zero on the same day.
    /// Nil when the dose's day is unknown.
    public static func daysSince(_ dose: MedicationDose, today: CalendarDay) -> Int? {
        guard let taken = dose.day else { return nil }
        return taken.days(until: today)
    }

    /// The local day the schedule next asks for a dose: the dose's day plus the schedule's days, counted
    /// in calendar days. Nil when the medication has no schedule or the dose's day is unknown.
    public static func nextByScheduleDay(_ medication: Medication, lastDose: MedicationDose) -> CalendarDay? {
        guard let scheduleDays = medication.scheduleDays, let taken = lastDose.day else { return nil }
        return taken.adding(days: scheduleDays)
    }

    /// The schedule's standing today. A medication without a schedule, or an archived one, is never due,
    /// whatever doses it has.
    /// A scheduled medication with no dose is waiting for its first one. Otherwise today is compared with
    /// the next scheduled day: before it is upcoming, on it is due today, after it is overdue by whole days.
    public static func status(
        of medication: Medication, lastDose: MedicationDose?, today: CalendarDay
    ) -> MedicationScheduleStatus {
        guard medication.scheduleDays != nil, !medication.isArchived else { return .notScheduled }
        guard let lastDose else { return .noDoseYet }
        guard let next = nextByScheduleDay(medication, lastDose: lastDose) else { return .noDoseYet }
        if today < next {
            return .upcoming(next)
        }
        if today == next {
            return .dueToday
        }
        return .overdue(days: next.days(until: today))
    }
}
