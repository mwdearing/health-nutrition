import Foundation
import NutritionDomain

/// A refusal from the medication store. Each case is a rule the store holds for every medication and dose,
/// whichever store keeps them, so a caller can show the same message for either.
public enum MedicationStoreError: Error, Sendable, Equatable {
    /// The store was closed; nothing is read or written through a closed store.
    case closed
    /// Another medication already has this name, ignoring case. Archived medications count too.
    case duplicateName
    /// The dose names a medication the store does not hold.
    case unknownMedication
    /// The dose's unit is not the medication's current unit.
    case unitMismatch
    /// A stored row that cannot be read: a bad identifier, an unknown unit, an unreadable amount, or a
    /// row that fails validation. The associated text names the row. Such a row fails the whole read.
    case corruptRecord(String)
}

/// Where the medication log is kept: the medications a person named and the doses they typed.
///
/// Every save validates its value first, so a refused save writes nothing. Reads return what was saved, in a
/// stable order, and a read that throws means the store cannot be trusted, never that the person has no
/// medications or doses.
public protocol MedicationStore: AnyObject, Sendable {
    /// Every stored medication, archived ones included, ordered by lowercased name and then by identifier.
    func medications() throws -> [Medication]
    /// Every stored dose, newest first by the time taken, then by identifier.
    func allDoses() throws -> [MedicationDose]
    /// The doses of one medication, newest first by the time taken, then by identifier.
    func doses(of medicationID: UUID) throws -> [MedicationDose]
    /// Writes the medication, replacing a stored medication with the same identifier. The name must be unique
    /// ignoring case across every medication, and the same medication may keep its own name in another case.
    func saveMedication(_ medication: Medication) throws
    /// Removes the medication and every dose of it in the same save. Removing one that is not stored is not an error.
    func removeMedication(id: UUID) throws
    /// Writes the dose, replacing a stored dose with the same identifier. The medication must be stored and the
    /// dose's unit must be the medication's current unit.
    func saveDose(_ dose: MedicationDose) throws
    /// Removes one dose. Removing a dose that is not stored is not an error.
    func removeDose(id: UUID) throws
    /// Records the medications and doses a restore is about to write, under its receipt, before the first is written.
    /// The record and the rows share one store, so a stop between them leaves the record that resume and undo read.
    func recordMedicationRestoreReceipt(_ receipt: String, planned: MedicationRestoreSet) throws
    /// The rows a restore recorded under this receipt and has not written yet, or nil when it recorded none.
    func medicationRestoreReceipt(_ receipt: String) throws -> MedicationRestoreSet?
    /// Forgets the receipt once nothing needs it. A receipt that is not there is not an error.
    func removeMedicationRestoreReceipt(_ receipt: String) throws
    /// Whether the restore's rows were all written, or nil when there is no receipt.
    func medicationRestoreReceiptDone(_ receipt: String) throws -> Bool?
    /// Marks the receipt's rows as all written, so a resume does not add them again. Refused while the receipt still
    /// lists a row to write.
    func markMedicationRestoreReceiptDone(_ receipt: String) throws
    /// Writes one restored medication and drops it from the receipt in the same save. Returns false, writing nothing,
    /// when a medication already holds its identifier or, ignoring case, its name. The medication leaves the receipt either way.
    func writeRestoredMedication(_ medication: Medication, receipt: String) throws -> Bool
    /// Writes one restored dose in its own unit and drops it from the receipt in the same save. Returns false, writing
    /// nothing, when a dose already holds the identifier or its medication is not stored. A dose keeps the unit it was
    /// logged in, which can differ from its medication's current unit. The dose leaves the receipt either way.
    func writeRestoredDose(_ dose: MedicationDose, receipt: String) throws -> Bool
    /// Every row the restore under this receipt wrote, from any run, so an undo removes exactly those.
    func medicationRestoreWritten(_ receipt: String) throws -> MedicationRestoreSet
    /// Undoes one dose a restore wrote: removes it only while the store holds exactly that dose, checked and removed in
    /// one save. In the same save the dose moves from the receipt's written rows back to its rows to write, so a retry
    /// adds it again. A dose already gone counts as undone. Returns false, changing nothing, when the stored dose
    /// differs. A nil receipt updates no receipt.
    func undoRestoredDose(_ dose: MedicationDose, receipt: String?) throws -> Bool
    /// Undoes one medication a restore wrote: removes it only while it is stored unchanged and holds no dose, checked and
    /// removed in one save, so a dose the person logs meanwhile is never removed with it. The receipt is updated in the
    /// same save, as for a dose. Returns false, changing nothing, when the medication differs or still holds a dose.
    func undoRestoredMedication(_ medication: Medication, receipt: String?) throws -> Bool
}

/// The medications and doses one restore will write, or has written, as a value a store can record under a receipt.
public struct MedicationRestoreSet: Sendable, Equatable {
    /// The medications, in the order the restore writes them.
    public let medications: [Medication]
    /// The doses, in the order the restore writes them, after the medications.
    public let doses: [MedicationDose]

    /// A set with the given medications and doses. An empty set is a restore with nothing left to write.
    public init(medications: [Medication] = [], doses: [MedicationDose] = []) {
        self.medications = medications
        self.doses = doses
    }
}

/// A store that keeps no receipts refuses a medication restore, so a row is never written without the record that undo
/// would need. Stores that do keep receipts override these.
extension MedicationStore {
    public func recordMedicationRestoreReceipt(_ receipt: String, planned: MedicationRestoreSet) throws {
        throw JournalImportError.corrupt("this medication store keeps no restore receipt")
    }
    public func medicationRestoreReceipt(_ receipt: String) throws -> MedicationRestoreSet? { nil }
    public func removeMedicationRestoreReceipt(_ receipt: String) throws {}
    public func medicationRestoreReceiptDone(_ receipt: String) throws -> Bool? { nil }
    public func markMedicationRestoreReceiptDone(_ receipt: String) throws {
        throw JournalImportError.corrupt("this medication store keeps no restore receipt")
    }
    public func writeRestoredMedication(_ medication: Medication, receipt: String) throws -> Bool {
        throw JournalImportError.corrupt("this medication store keeps no restore receipt")
    }
    public func writeRestoredDose(_ dose: MedicationDose, receipt: String) throws -> Bool {
        throw JournalImportError.corrupt("this medication store keeps no restore receipt")
    }
    public func medicationRestoreWritten(_ receipt: String) throws -> MedicationRestoreSet { MedicationRestoreSet() }
    public func undoRestoredDose(_ dose: MedicationDose, receipt: String?) throws -> Bool {
        throw JournalImportError.corrupt("this medication store keeps no restore receipt")
    }
    public func undoRestoredMedication(_ medication: Medication, receipt: String?) throws -> Bool {
        throw JournalImportError.corrupt("this medication store keeps no restore receipt")
    }
}

/// The one order every medication store reads in, so the SwiftData store and the in-memory store cannot disagree.
enum MedicationListOrder {
    /// Medications by lowercased name, then by identifier text in ascending order.
    static func medications(_ values: [Medication]) -> [Medication] {
        values.sorted { lhs, rhs in
            let leftName = lhs.name.lowercased()
            let rightName = rhs.name.lowercased()
            if leftName != rightName { return leftName < rightName }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Doses newest first by the time taken, then by identifier text in ascending order.
    static func doses(_ values: [MedicationDose]) -> [MedicationDose] {
        values.sorted { lhs, rhs in
            if lhs.takenAt != rhs.takenAt { return lhs.takenAt > rhs.takenAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// A medication store held in memory, for tests and for a caller that has nowhere to persist to.
///
/// It answers exactly what it was given, so a test can hold a store that refuses a write or throws on a read,
/// states a real store reaches too. `failReads` fails every read, and `refusesWrites` fails every write and changes nothing.
public final class InMemoryMedicationStore: MedicationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedMedications: [UUID: Medication] = [:]
    private var storedDoses: [UUID: MedicationDose] = [:]
    private let failReads: Bool
    private let refusesWrites: Bool

    /// Starts the store with the given medications and doses, which are kept as they are given.
    public init(
        medications: [Medication] = [], doses: [MedicationDose] = [], failReads: Bool = false, refusesWrites: Bool = false
    ) {
        self.failReads = failReads
        self.refusesWrites = refusesWrites
        for medication in medications { storedMedications[medication.id] = medication }
        for dose in doses { storedDoses[dose.id] = dose }
    }

    private struct Unsupported: Error {}

    /// Every stored medication, in the store's order.
    public func medications() throws -> [Medication] {
        if failReads { throw Unsupported() }
        return lock.withLock { MedicationListOrder.medications(Array(storedMedications.values)) }
    }

    /// Every stored dose, newest first.
    public func allDoses() throws -> [MedicationDose] {
        if failReads { throw Unsupported() }
        return lock.withLock { MedicationListOrder.doses(Array(storedDoses.values)) }
    }

    /// The doses of one medication, newest first.
    public func doses(of medicationID: UUID) throws -> [MedicationDose] {
        if failReads { throw Unsupported() }
        return lock.withLock {
            MedicationListOrder.doses(storedDoses.values.filter { $0.medicationID == medicationID })
        }
    }

    /// Writes the medication after validating it and checking the name is unique ignoring case.
    public func saveMedication(_ medication: Medication) throws {
        if refusesWrites { throw Unsupported() }
        try medication.validate()
        try lock.withLock {
            let name = medication.name.lowercased()
            if storedMedications.values.contains(where: { $0.id != medication.id && $0.name.lowercased() == name }) {
                throw MedicationStoreError.duplicateName
            }
            storedMedications[medication.id] = medication
        }
    }

    /// Removes the medication and its doses together.
    public func removeMedication(id: UUID) throws {
        if refusesWrites { throw Unsupported() }
        lock.withLock {
            storedMedications.removeValue(forKey: id)
            storedDoses = storedDoses.filter { $0.value.medicationID != id }
        }
    }

    /// Writes the dose after validating it, checking its medication is stored and its unit is that medication's unit.
    public func saveDose(_ dose: MedicationDose) throws {
        if refusesWrites { throw Unsupported() }
        try dose.validate()
        try lock.withLock {
            guard let medication = storedMedications[dose.medicationID] else {
                throw MedicationStoreError.unknownMedication
            }
            guard medication.unit == dose.unit else { throw MedicationStoreError.unitMismatch }
            storedDoses[dose.id] = dose
        }
    }

    /// Removes one dose. A dose that is not stored is left as it is.
    public func removeDose(id: UUID) throws {
        if refusesWrites { throw Unsupported() }
        lock.withLock { _ = storedDoses.removeValue(forKey: id) }
    }
}
