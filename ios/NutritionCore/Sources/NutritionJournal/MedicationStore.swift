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
