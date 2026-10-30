import Foundation
import NutritionDomain
import SwiftData

/// One stored medication. The identifier is kept as its UUID text and the unit as its raw value, so a row a
/// later build cannot read is found by the read path and fails it, rather than being skipped.
@Model
final class MedicationRecord {
    /// The medication's UUID as text.
    var id: String
    /// The name as the person typed it.
    var name: String
    /// The unit's raw value, `mg` or `mcg`.
    var unitText: String
    /// The schedule in days, or nil when none is set.
    var scheduleDays: Int?
    /// Whether the medication is archived. An archived medication keeps its doses and its name.
    var isArchived: Bool

    init(id: String, name: String, unitText: String, scheduleDays: Int?, isArchived: Bool) {
        self.id = id
        self.name = name
        self.unitText = unitText
        self.scheduleDays = scheduleDays
        self.isArchived = isArchived
    }
}

/// One stored dose. The amount is kept as exact decimal text, because a dose is what the person typed, and a
/// rounded one would state an amount they never entered.
@Model
final class MedicationDoseRecord {
    /// The dose's UUID as text.
    var id: String
    /// The UUID text of the medication the dose belongs to.
    var medicationID: String
    /// When the dose was taken.
    var takenAt: Date
    /// The time zone the dose was logged in, as its identifier.
    var timeZoneIdentifier: String
    /// The amount as exact decimal text, POSIX.
    var amountText: String
    /// The unit's raw value, the medication's unit when the dose was saved.
    var unitText: String
    /// The optional note the person typed.
    var note: String?

    init(
        id: String, medicationID: String, takenAt: Date, timeZoneIdentifier: String, amountText: String,
        unitText: String, note: String?
    ) {
        self.id = id
        self.medicationID = medicationID
        self.takenAt = takenAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.amountText = amountText
        self.unitText = unitText
        self.note = note
    }
}

/// The first and only schema of the medication store file. Its two models are the medication and dose rows above.
enum MedicationSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [MedicationRecord.self, MedicationDoseRecord.self] }
}

/// The migration plan for the medication store file. Version 1 is the only version, so it lists no stages.
enum MedicationMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MedicationSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Medications and doses in their own store file, `medications.store`, opened beside the journal and the goals.
/// Nothing here is shared or synced: the medication log is the person's own record.
///
/// Erasing deletes every row one at a time in one save, as the goal store does. A batch delete runs against the
/// persistent store immediately, so a save that then fails could not roll it back and would leave the file half-erased.
public final class SwiftDataMedicationStore: MedicationStore, JournalErasing, @unchecked Sendable {
    private let lock = NSLock()
    /// Held across each whole write, so a save and an erase cannot read the same rows at once.
    private let writeLock = NSLock()
    private var container: ModelContainer?

    /// Opens or creates the store file at `url`. Throws when the file cannot be opened or its schema cannot be migrated.
    public init(url: URL) throws {
        let schema = Schema(versionedSchema: MedicationSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(
            for: schema, migrationPlan: MedicationMigrationPlan.self, configurations: configuration)
    }

    /// Releases the file. Every later call throws `MedicationStoreError.closed`, and a new instance can reopen the file.
    public func close() {
        lock.withLock { container = nil }
    }

    private func openContainer() throws -> ModelContainer {
        try lock.withLock {
            guard let container else { throw MedicationStoreError.closed }
            return container
        }
    }

    /// The name the erase screen lists for this store.
    public var erasureName: String { "medications" }

    /// Every stored medication in the store's order. A row that cannot be read fails the whole read.
    public func medications() throws -> [Medication] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<MedicationRecord>())
        return MedicationListOrder.medications(try rows.map { try Self.decode($0) })
    }

    /// Every stored dose, newest first. A row that cannot be read fails the whole read.
    public func allDoses() throws -> [MedicationDose] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<MedicationDoseRecord>())
        return MedicationListOrder.doses(try rows.map { try Self.decode($0) })
    }

    /// The doses of one medication, newest first.
    public func doses(of medicationID: UUID) throws -> [MedicationDose] {
        try allDoses().filter { $0.medicationID == medicationID }
    }

    /// Writes the medication. It is validated before anything is written, and its name is checked against every
    /// other stored medication ignoring case, so a refused save leaves the file as it was.
    public func saveMedication(_ medication: Medication) throws {
        let container = try openContainer()
        try medication.validate()
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(container)
        let key = medication.id.uuidString
        let name = medication.name.lowercased()
        let rows = try context.fetch(FetchDescriptor<MedicationRecord>())
        if rows.contains(where: { $0.id != key && $0.name.lowercased() == name }) {
            throw MedicationStoreError.duplicateName
        }
        // The old row for this identifier goes in the same save as the new one, so a replace is never half-applied.
        for row in rows where row.id == key { context.delete(row) }
        context.insert(MedicationRecord(
            id: key, name: medication.name, unitText: medication.unit.rawValue,
            scheduleDays: medication.scheduleDays, isArchived: medication.isArchived))
        try context.save()
    }

    /// Removes the medication and every dose of it in one save. Removing a medication that is not stored is not an error.
    public func removeMedication(id: UUID) throws {
        let container = try openContainer()
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(container)
        let key = id.uuidString
        for row in try context.fetch(FetchDescriptor<MedicationDoseRecord>(
            predicate: #Predicate<MedicationDoseRecord> { $0.medicationID == key })) {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<MedicationRecord>(
            predicate: #Predicate<MedicationRecord> { $0.id == key })) {
            context.delete(row)
        }
        try context.save()
    }

    /// Writes the dose. It is validated first, then checked against its medication: the medication must be stored, and
    /// the dose's unit must be that medication's current unit. A refused dose writes nothing.
    public func saveDose(_ dose: MedicationDose) throws {
        let container = try openContainer()
        try dose.validate()
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(container)
        let medicationKey = dose.medicationID.uuidString
        guard let medication = try context.fetch(FetchDescriptor<MedicationRecord>(
            predicate: #Predicate<MedicationRecord> { $0.id == medicationKey })).first
        else {
            throw MedicationStoreError.unknownMedication
        }
        guard let storedUnit = MedicationUnit(rawValue: medication.unitText) else {
            throw MedicationStoreError.corruptRecord(medication.id)
        }
        guard storedUnit == dose.unit else { throw MedicationStoreError.unitMismatch }
        let key = dose.id.uuidString
        for old in try context.fetch(FetchDescriptor<MedicationDoseRecord>(
            predicate: #Predicate<MedicationDoseRecord> { $0.id == key })) {
            context.delete(old)
        }
        context.insert(MedicationDoseRecord(
            id: key, medicationID: medicationKey, takenAt: dose.takenAt,
            timeZoneIdentifier: dose.timeZoneIdentifier, amountText: DecimalText.encode(dose.amount),
            unitText: dose.unit.rawValue, note: dose.note))
        try context.save()
    }

    /// Removes one dose. A dose that is not stored is not an error.
    public func removeDose(id: UUID) throws {
        let container = try openContainer()
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(container)
        let key = id.uuidString
        for row in try context.fetch(FetchDescriptor<MedicationDoseRecord>(
            predicate: #Predicate<MedicationDoseRecord> { $0.id == key })) {
            context.delete(row)
        }
        try context.save()
    }

    /// Removes every medication and every dose. The rows are deleted one at a time in one save, so the erase is
    /// all or nothing, and the store stays open afterwards.
    public func eraseAll() throws {
        let container = try openContainer()
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<MedicationDoseRecord>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<MedicationRecord>()) { context.delete(row) }
        try context.save()
    }

    /// Reads one medication row back. Any field that cannot be read, or a medication that fails `validate()`, is a
    /// corrupt row: none of it is returned.
    private static func decode(_ row: MedicationRecord) throws -> Medication {
        let corrupt = MedicationStoreError.corruptRecord(row.id)
        guard let id = UUID(uuidString: row.id), let unit = MedicationUnit(rawValue: row.unitText) else {
            throw corrupt
        }
        let medication = Medication(
            id: id, name: row.name, unit: unit, scheduleDays: row.scheduleDays, isArchived: row.isArchived)
        do {
            try medication.validate()
        } catch {
            throw corrupt
        }
        return medication
    }

    /// Reads one dose row back. The amount must be a whole decimal, and the dose must pass `validate()`; otherwise
    /// the row is corrupt and none of it is returned.
    private static func decode(_ row: MedicationDoseRecord) throws -> MedicationDose {
        let corrupt = MedicationStoreError.corruptRecord(row.id)
        guard let id = UUID(uuidString: row.id), let medicationID = UUID(uuidString: row.medicationID),
            let unit = MedicationUnit(rawValue: row.unitText),
            DecimalText.isValidDecimalText(row.amountText), let amount = DecimalText.decode(row.amountText),
            !amount.isNaN
        else {
            throw corrupt
        }
        let dose = MedicationDose(
            id: id, medicationID: medicationID, takenAt: row.takenAt,
            timeZoneIdentifier: row.timeZoneIdentifier, amount: amount, unit: unit, note: row.note)
        do {
            try dose.validate()
        } catch {
            throw corrupt
        }
        return dose
    }

    /// Rewrites a stored medication into a shape the read path cannot decode. A nil argument leaves that field as it is,
    /// which is a valid value for a row the store wrote.
    ///
    /// `saveMedication` validates before it writes, so the store's own API cannot produce such a row. A test of the
    /// read path plants one through this hook, as the goal store's hooks do.
    func writeCorruptMedicationForTesting(id: UUID, name: String? = nil, unitText: String? = nil) throws {
        let context = ModelContext(try openContainer())
        let key = id.uuidString
        guard let row = try context.fetch(FetchDescriptor<MedicationRecord>(
            predicate: #Predicate<MedicationRecord> { $0.id == key })).first
        else {
            throw MedicationStoreError.corruptRecord(key)
        }
        if let name { row.name = name }
        if let unitText { row.unitText = unitText }
        try context.save()
    }

    /// Rewrites a stored dose into a shape the read path cannot decode. A nil argument leaves that field as it is.
    ///
    /// `saveDose` validates before it writes, so the store's own API cannot produce such a row. A test of the read path
    /// plants one through this hook, as the goal store's hooks do.
    func writeCorruptDoseForTesting(
        id: UUID, amountText: String? = nil, unitText: String? = nil, timeZoneIdentifier: String? = nil
    ) throws {
        let context = ModelContext(try openContainer())
        let key = id.uuidString
        guard let row = try context.fetch(FetchDescriptor<MedicationDoseRecord>(
            predicate: #Predicate<MedicationDoseRecord> { $0.id == key })).first
        else {
            throw MedicationStoreError.corruptRecord(key)
        }
        if let amountText { row.amountText = amountText }
        if let unitText { row.unitText = unitText }
        if let timeZoneIdentifier { row.timeZoneIdentifier = timeZoneIdentifier }
        try context.save()
    }
}
