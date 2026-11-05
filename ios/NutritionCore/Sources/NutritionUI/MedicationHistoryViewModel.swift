import Foundation
import NutritionDomain
import NutritionJournal

/// One logged dose as the history lists it: its day and time in the zone it was logged in, its amount and its note.
/// Each field is text already read for the screen, so the view only places it. A dose's site is never shown.
public struct MedicationHistoryRow: Equatable, Identifiable {
    /// The dose's identifier.
    public let id: UUID
    /// The local day the dose was taken on, such as "Apr 10, 2026", or "Unknown day" when the day cannot be read.
    public let dayText: String
    /// The local time the dose was taken at, such as "9:30 AM", or empty when the zone cannot be read.
    public let timeText: String
    /// The amount and unit, such as "2.5 mg".
    public let amountText: String
    /// The note the person wrote, nil when there is none.
    public let noteText: String?
}

/// The values the history's edit form starts from: the stored amount, time and note of one dose. The site is not
/// part of the form, so it is never read here.
public struct MedicationDoseDraft: Equatable {
    /// The amount as stored, such as "2.5".
    public let amountText: String
    /// The instant the dose was taken.
    public let takenAt: Date
    /// The note as stored, or empty when there is none.
    public let noteText: String
}

/// One medication's history: its doses, newest first, each read in the zone it was logged in. The person can correct
/// a dose's amount, time or note, or delete a dose. Plain facts only; nothing here offers a view on a dose.
///
/// A dose's site is saved with the dose but is never read back here, so it is never shown.
@MainActor
public final class MedicationHistoryViewModel: ObservableObject {
    private let store: MedicationStore
    /// The medication this history belongs to.
    public let medicationID: UUID
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    /// The medication's name, or empty when the medication cannot be read.
    @Published public private(set) var title: String = ""
    /// The medication's doses, newest first, in the store's order.
    @Published public private(set) var rows: [MedicationHistoryRow] = []
    /// A message when the medication or its doses cannot be read, nil otherwise.
    @Published public private(set) var errorMessage: String?
    /// Whether a dose was edited or deleted here, so the list behind can read the log again.
    @Published public private(set) var didChange = false
    /// Whether a reminder can be offered: the medication is active and keeps a schedule.
    @Published public private(set) var canRemind = false
    /// Called after a dose is saved or deleted here, so the medication reminders follow the change at once.
    public var onLogChanged: (() -> Void)?

    /// A view model over one medication's doses. `now` is kept for the same clock as the list, and `timeZone` is the
    /// device's zone, which a changed time takes.
    public init(
        store: MedicationStore, medicationID: UUID, now: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.store = store
        self.medicationID = medicationID
        self.now = now
        self.timeZone = timeZone
    }

    /// Reads the medication and its doses and rebuilds the rows. A read that fails leaves no rows and sets the message.
    /// An archived medication shows its history too.
    public func load() {
        guard let medications = try? store.medications(), let doses = try? store.doses(of: medicationID) else {
            rows = []
            errorMessage = "Could not read the medication log."
            return
        }
        guard let medication = medications.first(where: { $0.id == medicationID }) else {
            rows = []
            errorMessage = "This medication is no longer in the list."
            return
        }
        title = medication.name
        canRemind = !medication.isArchived && medication.scheduleDays != nil
        rows = doses.map(Self.row(for:))
        errorMessage = nil
    }

    /// The stored amount, time and note of one dose of this medication, or nil when it is not stored.
    public func draft(for doseID: UUID) -> MedicationDoseDraft? {
        guard let stored = storedDose(id: doseID) else { return nil }
        return MedicationDoseDraft(
            amountText: DecimalFormatting.text(stored.amount), takenAt: stored.takenAt,
            noteText: stored.note ?? "")
    }

    /// Saves the edited amount, time and note of a dose and reloads. The dose keeps its unit, site and, when the time
    /// is unchanged, its zone; a changed time takes the device's zone. Returns nil on success, or the message to show
    /// when nothing is saved.
    @discardableResult
    public func saveEdit(doseID: UUID, amountText: String, takenAt: Date, noteText: String) -> String? {
        guard let stored = storedDose(id: doseID) else {
            return "This dose is no longer in the log."
        }
        guard let amount = AmountParser.parseTyped(amountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "Enter an amount above 0."
        }
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A time left within the same minute is unchanged: the picker may drop seconds, so the stored instant and zone
        // are kept as they are.
        let sameMinute = floor(takenAt.timeIntervalSinceReferenceDate / 60)
            == floor(stored.takenAt.timeIntervalSinceReferenceDate / 60)
        let savedTakenAt = sameMinute ? stored.takenAt : takenAt
        let zoneID = sameMinute ? stored.timeZoneIdentifier : timeZone().identifier
        let dose = MedicationDose(
            id: stored.id, medicationID: stored.medicationID, takenAt: savedTakenAt, timeZoneIdentifier: zoneID,
            amount: amount, unit: stored.unit, site: stored.site, note: note.isEmpty ? nil : note)
        do {
            try dose.validate()
            try store.saveDose(dose)
        } catch {
            return MedicationLogViewModel.doseMessage(for: error)
        }
        didChange = true
        load()
        onLogChanged?()
        return nil
    }

    /// Removes one dose and reloads. A failure sets the message and changes nothing else, so the rows stay as they were.
    public func deleteDose(id: UUID) {
        do {
            try store.removeDose(id: id)
        } catch {
            errorMessage = "Could not delete the dose."
            return
        }
        didChange = true
        load()
        onLogChanged?()
    }

    // MARK: - Reading

    /// The stored dose with this identifier among this medication's doses, or nil when it is not stored or cannot be read.
    private func storedDose(id: UUID) -> MedicationDose? {
        guard let doses = try? store.doses(of: medicationID) else { return nil }
        return doses.first(where: { $0.id == id })
    }

    /// The row for one dose, with its day and time read in the dose's own zone.
    private static func row(for dose: MedicationDose) -> MedicationHistoryRow {
        let amount = "\(MedicationLogViewModel.doseAmountText(dose.amount)) \(dose.unit.rawValue)"
        guard let day = dose.day, let zone = TimeZone(identifier: dose.timeZoneIdentifier) else {
            return MedicationHistoryRow(
                id: dose.id, dayText: "Unknown day", timeText: "", amountText: amount, noteText: dose.note)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "h:mm a"
        return MedicationHistoryRow(
            id: dose.id, dayText: BodyActivityViewModel.dayText(day), timeText: formatter.string(from: dose.takenAt),
            amountText: amount, noteText: dose.note)
    }
}
