import Foundation
import NutritionDomain
import NutritionJournal

/// Somewhere the Medication log's Settings switch is kept. The switch is stored with the display preferences,
/// so Erase all data clears it with them. Turning it off hides the log and keeps its data.
public protocol MedicationLogPreferences: AnyObject {
    /// Whether the Medication log is shown. An absent value reads as off.
    var isMedicationLogOn: Bool { get }
    /// Shows or hides the Medication log. Nothing stored is removed either way.
    func setMedicationLogOn(_ on: Bool)
}

/// One medication as the list shows it. Each field is text already read for the screen, so the view only places it.
public struct MedicationRow: Equatable, Identifiable {
    /// The medication's identifier.
    public let id: UUID
    /// The name the person typed, as stored.
    public let name: String
    /// The unit the medication's doses are logged in, such as "mg".
    public let unitText: String
    /// "Every day" or "Every N days" when the person keeps a schedule, nil otherwise.
    public let scheduleText: String?
    /// The last dose with its amount, day and time, or "No dose logged yet".
    public let lastDoseText: String
    /// "Today", "1 day since" or "N days since" the last dose, nil when there is no dose or its day is unknown.
    public let daysSinceText: String?
    /// The schedule's standing: the next scheduled day, "Due today" or how many days overdue. Nil when the
    /// medication has no schedule, is archived, or has no dose yet.
    public let statusText: String?
    /// Whether the medication is archived.
    public let isArchived: Bool
}

/// The Medication log's screens: the list of medications with their last dose and schedule standing, adding a
/// medication, logging a dose with Undo, and archiving. Plain facts only; nothing here offers a view on, checks or
/// changes a dose.
///
/// A dose's site is saved with the dose but is never read back here, so it is never shown.
@MainActor
public final class MedicationLogViewModel: ObservableObject {
    private let store: MedicationStore
    private let preferences: DisplayPreferences
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    /// The identifier of the dose the last successful log saved, so Undo can remove it.
    private var lastLoggedDoseID: UUID?

    /// The active medications, in the store's order.
    @Published public private(set) var rows: [MedicationRow] = []
    /// The archived medications, in the store's order.
    @Published public private(set) var archivedRows: [MedicationRow] = []
    /// A message when the medications or doses cannot be read, nil otherwise.
    @Published public private(set) var errorMessage: String?
    /// The line for the Undo button after a dose is logged, nil when there is nothing to undo.
    @Published public private(set) var undoText: String?

    /// A view model over the medication store. `now` and `timeZone` are read on each load and save, so a test
    /// can fix the day and the device's zone.
    public init(
        store: MedicationStore, preferences: DisplayPreferences, now: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.store = store
        self.preferences = preferences
        self.now = now
        self.timeZone = timeZone
    }

    /// Whether the Medication log is shown. Reads and writes the preference when the preferences keep it;
    /// otherwise it reads off and ignores writes.
    public var isOn: Bool {
        get { (preferences as? MedicationLogPreferences)?.isMedicationLogOn ?? false }
        set {
            (preferences as? MedicationLogPreferences)?.setMedicationLogOn(newValue)
            objectWillChange.send()
        }
    }

    /// Reads the medications and doses and rebuilds the rows. A read that fails leaves no rows and sets the message.
    public func load() {
        guard let today = today(),
            let medications = try? store.medications(),
            let doses = try? store.allDoses()
        else {
            rows = []
            archivedRows = []
            errorMessage = "Could not read the medication log."
            return
        }
        let built = medications.map { row(for: $0, doses: doses, today: today) }
        rows = built.filter { !$0.isArchived }
        archivedRows = built.filter { $0.isArchived }
        errorMessage = nil
    }

    /// Saves a new medication and reloads. Returns nil on success, or the message to show when it is not saved.
    /// An empty schedule means none.
    @discardableResult
    public func addMedication(name: String, unit: MedicationUnit, scheduleDaysText: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheduleText = scheduleDaysText.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheduleDays: Int?
        if !scheduleText.isEmpty {
            guard let days = Int(scheduleText) else { return Self.scheduleMessage }
            scheduleDays = days
        }
        let medication = Medication(name: trimmedName, unit: unit, scheduleDays: scheduleDays)
        do {
            try medication.validate()
            try store.saveMedication(medication)
        } catch {
            return Self.addMessage(for: error)
        }
        load()
        return nil
    }

    /// Saves a dose of the medication and reloads, and offers Undo for it. Returns nil on success, or the message
    /// to show when it is not saved. The dose takes the medication's unit and the device's time zone.
    @discardableResult
    public func logDose(
        medicationID: UUID, amountText: String, takenAt: Date, siteText: String, noteText: String
    ) -> String? {
        let medications: [Medication]
        do {
            medications = try store.medications()
        } catch {
            return "Could not save the dose."
        }
        guard let medication = medications.first(where: { $0.id == medicationID }) else {
            return "This medication is no longer in the list."
        }
        guard let amount = AmountParser.parseTyped(amountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "Enter an amount above 0."
        }
        let site = siteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let dose = MedicationDose(
            medicationID: medicationID, takenAt: takenAt, timeZoneIdentifier: timeZone().identifier, amount: amount,
            unit: medication.unit, site: site.isEmpty ? nil : site, note: note.isEmpty ? nil : note)
        do {
            try dose.validate()
            try store.saveDose(dose)
        } catch {
            return Self.doseMessage(for: error)
        }
        lastLoggedDoseID = dose.id
        undoText = "Logged \(amount.description) \(medication.unit.rawValue) of \(medication.name)"
        load()
        return nil
    }

    /// Removes only the dose the last log saved, clears the Undo line and reloads. A failure sets the message.
    public func undoLastDose() {
        guard let doseID = lastLoggedDoseID else { return }
        lastLoggedDoseID = nil
        undoText = nil
        do {
            try store.removeDose(id: doseID)
        } catch {
            errorMessage = "Could not undo the dose."
            return
        }
        load()
    }

    /// Archives or unarchives the medication, keeping its doses, and reloads. A failure sets the message.
    public func setArchived(_ medicationID: UUID, archived: Bool) {
        guard let medication = (try? store.medications())?.first(where: { $0.id == medicationID }) else {
            errorMessage = "Could not update the medication."
            return
        }
        let changed = Medication(
            id: medication.id, name: medication.name, unit: medication.unit, scheduleDays: medication.scheduleDays,
            isArchived: archived)
        do {
            try store.saveMedication(changed)
        } catch {
            errorMessage = "Could not update the medication."
            return
        }
        load()
    }

    // MARK: - Building rows

    /// The day today is on the Gregorian calendar in the device's zone, or nil when the calendar cannot read it.
    private func today() -> CalendarDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone()
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }

    private func row(for medication: Medication, doses: [MedicationDose], today: CalendarDay) -> MedicationRow {
        let last = MedicationLog.lastDose(of: medication.id, in: doses)
        let standing = MedicationLog.status(of: medication, lastDose: last, today: today)
        return MedicationRow(
            id: medication.id,
            name: medication.name,
            unitText: medication.unit.rawValue,
            scheduleText: Self.scheduleText(medication.scheduleDays),
            lastDoseText: last.map(Self.lastDoseText) ?? "No dose logged yet",
            daysSinceText: last.flatMap { MedicationLog.daysSince($0, today: today) }.map(Self.daysSinceText),
            statusText: Self.statusText(standing),
            isArchived: medication.isArchived)
    }

    private static func scheduleText(_ days: Int?) -> String? {
        guard let days else { return nil }
        return days == 1 ? "Every day" : "Every \(days) days"
    }

    private static func daysSinceText(_ days: Int) -> String {
        switch days {
        case 0: return "Today"
        case 1: return "1 day since"
        default: return "\(days) days since"
        }
    }

    /// The last dose read in the dose's own zone. A dose whose zone or day cannot be read shows its amount and unit only.
    private static func lastDoseText(_ dose: MedicationDose) -> String {
        let amount = dose.amount.description
        guard let day = dose.day, let zone = TimeZone(identifier: dose.timeZoneIdentifier) else {
            return "Last dose \(amount) \(dose.unit.rawValue)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: dose.takenAt)
        return "Last dose \(amount) \(dose.unit.rawValue) on \(BodyActivityViewModel.dayText(day)) at \(time)"
    }

    private static func statusText(_ standing: MedicationScheduleStatus) -> String? {
        switch standing {
        case .notScheduled, .noDoseYet:
            return nil
        case .upcoming(let day):
            return "Next by your schedule: \(BodyActivityViewModel.dayText(day))"
        case .dueToday:
            return "Due today"
        case .overdue(let days):
            return days == 1 ? "Overdue by 1 day" : "Overdue by \(days) days"
        }
    }

    // MARK: - Messages

    private static let scheduleMessage = "Enter a whole number of days from 1 to 28."

    /// The message for a medication that is not saved, from the domain rule or the store's refusal.
    private static func addMessage(for error: Error) -> String {
        switch error {
        case MedicationError.nameEmpty, MedicationError.nameNotTrimmed:
            return "Enter a name."
        case MedicationError.nameHasLineBreak:
            return "Use one line for the name."
        case MedicationError.nameTooLong:
            return "Use 60 characters or fewer."
        case MedicationError.scheduleOutOfRange:
            return scheduleMessage
        case MedicationStoreError.duplicateName:
            return "A medication with this name is already in the list."
        default:
            return "Could not save the medication."
        }
    }

    /// The message for a dose that is not saved, from the domain rule or the store's refusal.
    private static func doseMessage(for error: Error) -> String {
        switch error {
        case MedicationError.amountNotPositive:
            return "Enter an amount above 0."
        case MedicationError.amountTooLarge:
            return "Enter 1000 or less."
        case MedicationError.amountTooPrecise:
            return "Use up to 3 decimal places."
        case MedicationError.siteHasLineBreak:
            return "Use one line for the site."
        case MedicationError.siteTooLong:
            return "Use 40 characters or fewer for the site."
        case MedicationError.noteTooLong:
            return "Use 200 characters or fewer for the note."
        case MedicationStoreError.unknownMedication:
            return "This medication is no longer in the list."
        default:
            return "Could not save the dose."
        }
    }
}
