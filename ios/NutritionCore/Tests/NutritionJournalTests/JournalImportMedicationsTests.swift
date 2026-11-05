import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The medication log in a version 9 export, restored add-only by id: a medication or dose the device already holds
/// is never replaced, and the restore is recorded under its receipt before the first row is written, so a stop can be
/// finished or undone from the record, as goals are.
final class JournalImportMedicationsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func journal() throws -> SwiftDataJournalStore {
        let store = try SwiftDataJournalStore(url: try directory().appendingPathComponent("journal.store"))
        addTeardownBlock { store.close() }
        return store
    }

    private func medicationStore() throws -> SwiftDataMedicationStore {
        let store = try SwiftDataMedicationStore(url: try directory().appendingPathComponent("medications.store"))
        addTeardownBlock { store.close() }
        return store
    }

    private let vial = Medication(
        id: UUID(uuidString: "0A000000-0000-4000-8000-000000000001")!, name: "Example vial", unit: .mg,
        scheduleDays: 7)
    private let pen = Medication(
        id: UUID(uuidString: "0A000000-0000-4000-8000-000000000002")!, name: "Example pen", unit: .units,
        isArchived: true)
    private let tablet = Medication(
        id: UUID(uuidString: "0A000000-0000-4000-8000-000000000003")!, name: "Example tablet", unit: .mg)

    private func dose(
        _ number: Int, _ medication: Medication, amount: Decimal = 2, unit: MedicationUnit? = nil,
        site: String? = nil, note: String? = nil
    ) -> MedicationDose {
        MedicationDose(
            id: UUID(uuidString: "0D000000-0000-4000-8000-00000000000\(number)")!, medicationID: medication.id,
            takenAt: Date(timeIntervalSince1970: TimeInterval(1_776_000_000 + number * 86_400)),
            timeZoneIdentifier: "UTC", amount: amount, unit: unit ?? medication.unit, site: site, note: note)
    }

    private var fileDoses: [MedicationDose] {
        [dose(1, vial, amount: Decimal(string: "2.5")!, site: "Left side", note: "After lunch"), dose(2, vial, amount: 5),
         dose(3, pen, amount: 1000)]
    }

    /// A document with no entries and only the given medication log, encoded as the app writes it.
    private func medicationsExport(
        _ medications: [Medication], _ doses: [MedicationDose],
        schemaVersion: Int = JournalExport.currentSchemaVersion
    ) throws -> Data {
        try JournalExporter.encode(
            JournalExport(
                schemaVersion: schemaVersion, exportedAt: Date(timeIntervalSince1970: 1_777_000_000),
                appVersion: "test", intakes: [], tombstones: [], favorites: [], goals: [],
                medications: medications.map { JournalExportMedication(medication: $0) },
                medicationDoses: doses.map { JournalExportMedicationDose(dose: $0) }))
    }

    private func fullExport() throws -> Data { try medicationsExport([vial, pen], fileDoses) }

    /// The same document with one change made to its JSON, so a shape rule is tested on the bytes a file carries.
    private func mutated(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func doseIDs(_ store: MedicationStore) throws -> Set<UUID> { Set(try store.allDoses().map(\.id)) }

    private func importFile(_ data: Data, into store: MedicationStore?, journal: SwiftDataJournalStore? = nil) throws
        -> JournalImportSummary
    {
        try JournalImporter.importExport(data, into: try journal ?? self.journal(), favorites: nil, medications: store)
    }

    /// Asserts the file is refused with exactly `expected`, so a refusal for another reason fails the test.
    private func assertRefused(
        _ data: Data, into store: MedicationStore, as expected: JournalImportError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try importFile(data, into: store), file: file, line: line) { error in
            XCTAssertEqual(error as? JournalImportError, expected, file: file, line: line)
        }
    }

    private let badMedicationID = JournalImportError.corrupt(
        "the export lists a medication with an id that is not a UUID, twice, or a unit this build does not know")
    private let badDoseID = JournalImportError.corrupt("the export lists a dose with an id that is not a UUID, or twice")

    // MARK: - Adding

    func testMissingMedicationsAndDosesAreAddedWithEveryFieldAndCounted() throws {
        let store = try medicationStore()

        let summary = try importFile(try fullExport(), into: store)

        XCTAssertEqual(try store.medications(), [pen, vial])
        XCTAssertEqual(try doseIDs(store), Set(fileDoses.map(\.id)))
        XCTAssertEqual(try store.allDoses().first { $0.id == fileDoses[0].id }, fileDoses[0], "site and note come back")
        XCTAssertEqual(summary.medications, 2)
        XCTAssertEqual(summary.medicationDoses, 3)
    }

    func testAnExistingMedicationIsNeverReplacedAndItsMissingDosesAreAdded() throws {
        let store = try medicationStore()
        let own = Medication(id: vial.id, name: "Example vial", unit: .mg, scheduleDays: 14)
        try store.saveMedication(own)

        let summary = try importFile(try medicationsExport([vial], Array(fileDoses.prefix(2))), into: store)

        XCTAssertEqual(try store.medications(), [own], "the device copy is kept")
        XCTAssertEqual(summary.medications, 0)
        XCTAssertEqual(summary.medicationDoses, 2)
        XCTAssertEqual(try store.doses(of: vial.id).count, 2)
    }

    func testAnExistingDoseIsNeverReplaced() throws {
        let store = try medicationStore()
        try store.saveMedication(vial)
        let own = dose(1, vial, amount: 3)
        try store.saveDose(own)

        let summary = try importFile(try medicationsExport([vial], Array(fileDoses.prefix(2))), into: store)

        XCTAssertEqual(try store.allDoses().first { $0.id == own.id }, own)
        XCTAssertEqual(summary.medicationDoses, 1)
        XCTAssertEqual(try store.allDoses().count, 2)
    }

    func testReimportingTheSameFileChangesNothing() throws {
        let store = try medicationStore()
        let data = try fullExport()
        _ = try importFile(data, into: store)

        let again = try importFile(data, into: store)

        XCTAssertEqual(again.medications, 0)
        XCTAssertEqual(again.medicationDoses, 0)
        XCTAssertEqual(try store.medications().count, 2)
        XCTAssertEqual(try store.allDoses().count, 3)
    }

    func testAMedicationWhoseNameIsTakenIsLeftOutWithItsDoses() throws {
        let store = try medicationStore()
        let own = Medication(name: "Example vial", unit: .mg)
        try store.saveMedication(own)

        let summary = try importFile(try medicationsExport([vial], Array(fileDoses.prefix(2))), into: store)

        XCTAssertEqual(try store.medications(), [own], "a restore does not choose between two medications of one name")
        XCTAssertEqual(try store.allDoses(), [])
        XCTAssertEqual(summary.medications, 0)
        XCTAssertEqual(summary.medicationDoses, 0)
    }

    func testAMedicationWhoseIDIsStoredUnderAnotherNameIsLeftOutWithItsDoses() throws {
        let store = try medicationStore()
        let renamed = Medication(id: vial.id, name: "Example other", unit: .mg)
        try store.saveMedication(renamed)

        let summary = try importFile(try medicationsExport([vial], Array(fileDoses.prefix(2))), into: store)

        XCTAssertEqual(try store.medications(), [renamed], "the device's medication is kept as it is")
        XCTAssertEqual(try store.allDoses(), [], "a dose never lands on a medication of another name")
        XCTAssertEqual(summary.medications, 0)
        XCTAssertEqual(summary.medicationDoses, 0)
    }

    func testADoseForADeviceMedicationWithAnotherUnitIsAddedInItsOwnUnit() throws {
        let store = try medicationStore()
        let own = Medication(id: vial.id, name: "Example vial", unit: .mL)
        try store.saveMedication(own)

        let summary = try importFile(try medicationsExport([vial], [fileDoses[1]]), into: store)

        XCTAssertEqual(try store.medications(), [own], "the device's medication is kept as it is")
        XCTAssertEqual(try store.allDoses(), [fileDoses[1]], "the dose keeps the unit it was logged in")
        XCTAssertEqual(summary.medicationDoses, 1)
    }

    // MARK: - Refusals

    func testADoseWhoseMedicationIsNotInTheFileIsRefusedAndNothingIsWritten() throws {
        let store = try medicationStore()
        try store.saveMedication(vial)

        assertRefused(
            try medicationsExport([pen], [fileDoses[1], fileDoses[2]]), into: store,
            as: .corrupt("the dose \(fileDoses[1].id.uuidString) names a medication that is not in the export"))

        XCTAssertEqual(try store.medications(), [vial], "a refused file writes nothing")
        XCTAssertEqual(try store.allDoses(), [])
    }

    func testADoseLoggedBeforeAUnitChangeRestoresInItsOwnUnit() throws {
        // The app keeps the old unit on doses logged before a medication's unit changed, and exports them so.
        let changed = Medication(id: vial.id, name: vial.name, unit: .mcg, scheduleDays: vial.scheduleDays)
        let before = dose(1, vial, amount: 2)
        let after = dose(2, changed, amount: 500)
        let store = try medicationStore()

        let summary = try importFile(try medicationsExport([changed], [before, after]), into: store)

        XCTAssertEqual(try store.medications(), [changed])
        XCTAssertEqual(try store.allDoses().sorted { $0.id.uuidString < $1.id.uuidString }, [before, after])
        XCTAssertEqual(try store.allDoses().first { $0.id == before.id }?.unit, .mg)
        XCTAssertEqual(summary.medicationDoses, 2)
    }

    func testTwoMedicationsWithOneNameAreRefusedAndNothingIsWritten() throws {
        let store = try medicationStore()
        let twin = Medication(name: "example VIAL", unit: .mL)

        assertRefused(
            try medicationsExport([vial, twin], [fileDoses[0]]), into: store,
            as: .corrupt("the export lists two medications named example VIAL"))

        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
    }

    func testAMedicationOrDoseThatBreaksARuleIsRefused() throws {
        let store = try medicationStore()
        let doseBreaksARule = JournalImportError.corrupt("the dose \(dose(2, vial).id.uuidString) breaks a rule this build keeps")
        assertRefused(try medicationsExport([vial], [dose(2, vial, amount: 0)]), into: store, as: doseBreaksARule)
        assertRefused(try medicationsExport([vial], [dose(2, vial, amount: 1001)]), into: store, as: doseBreaksARule)
        let spaced = Medication(name: " Example vial", unit: .mg)
        assertRefused(
            try medicationsExport([spaced], []), into: store,
            as: .corrupt("the medication \(spaced.id.uuidString) breaks a rule this build keeps"))
        assertRefused(try mutated(try fullExport()) { root in
            var list = root["medications"] as? [[String: Any]] ?? []
            list[0]["unit"] = "grains"
            root["medications"] = list
        }, into: store, as: badMedicationID)
        assertRefused(try mutated(try fullExport()) { root in
            var list = root["medication_doses"] as? [[String: Any]] ?? []
            list[0]["id"] = "not an id"
            root["medication_doses"] = list
        }, into: store, as: badDoseID)
        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
    }

    func testTheSameIDTwiceIsRefused() throws {
        let store = try medicationStore()
        assertRefused(try medicationsExport([vial], [fileDoses[1], fileDoses[1]]), into: store, as: badDoseID)
        assertRefused(try medicationsExport([vial, vial], []), into: store, as: badMedicationID)
        XCTAssertEqual(try store.medications(), [])
    }

    func testMedicationsInAFileWithoutAMedicationStoreAreRefused() throws {
        XCTAssertThrowsError(try importFile(try fullExport(), into: nil)) { error in
            guard case JournalImportError.corrupt = error else { return XCTFail("expected corrupt, got \(error)") }
        }
    }

    func testAnUnknownKeyInsideADoseIsRefusedAsMalformed() throws {
        let data = try mutated(try fullExport()) { root in
            var list = root["medication_doses"] as? [[String: Any]] ?? []
            list[0]["extra"] = "x"
            root["medication_doses"] = list
        }
        XCTAssertThrowsError(try importFile(data, into: try medicationStore())) { error in
            guard case JournalImportError.malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    func testAVersion9FileMustStateBothLists() throws {
        let data = try mutated(try fullExport()) { root in root.removeValue(forKey: "medication_doses") }
        XCTAssertThrowsError(try importFile(data, into: try medicationStore())) { error in
            guard case JournalImportError.malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    // MARK: - Earlier versions

    func testAVersion8FileHasNoMedicationsAndStillImports() throws {
        let store = try medicationStore()
        let data = try medicationsExport([], [], schemaVersion: 8)

        let summary = try importFile(data, into: store)
        _ = try importFile(data, into: nil)

        XCTAssertEqual(summary.medications, 0)
        XCTAssertEqual(summary.medicationDoses, 0)
        XCTAssertEqual(try store.medications(), [])
    }

    func testAVersion8FileThatCarriesMedicationListsIsRefusedAsMalformed() throws {
        let data = try mutated(try medicationsExport([], [], schemaVersion: 8)) { root in
            root["medications"] = []
            root["medication_doses"] = []
        }
        XCTAssertThrowsError(try importFile(data, into: try medicationStore())) { error in
            guard case JournalImportError.malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    // MARK: - Receipt, resume and undo

    func testARestoreReceiptIsNotAMedicationAndIsNotExported() throws {
        let store = try medicationStore()
        try store.recordMedicationRestoreReceipt("digest-a", planned: MedicationRestoreSet(medications: [vial], doses: []))

        XCTAssertEqual(try store.medications(), [], "a receipt row must not read back as a medication")
        XCTAssertEqual(try store.allDoses(), [])
        let export = try JournalExporter.makeExport(
            store: try journal(), goals: InMemoryGoalStore(), medications: store, appVersion: "test",
            exportedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(export.medications, [], "a receipt row must not export as a medication")
        XCTAssertEqual(
            try store.medicationRestoreReceipt("digest-a"), MedicationRestoreSet(medications: [vial], doses: []))
    }

    func testAFreshRestoreLeavesNoReceiptBehind() throws {
        let store = try medicationStore()
        let data = try fullExport()
        _ = try importFile(data, into: store)
        XCTAssertNil(try store.medicationRestoreReceipt(JournalImporter.fileDigest(data)))
    }

    func testEveryRowWrittenIsOneTheReceiptNames() throws {
        let base = try medicationStore()
        let data = try fullExport()
        let digest = JournalImporter.fileDigest(data)
        let store = ScriptedMedicationStore(base: base) { id, base in
            let planned = try XCTUnwrap(try base.medicationRestoreReceipt(digest))
            XCTAssertTrue(
                planned.medications.contains { $0.id == id } || planned.doses.contains { $0.id == id },
                "\(id) written but not recorded")
        }
        let summary = try importFile(data, into: store)
        XCTAssertEqual(summary.medicationDoses, 3)
    }

    /// A stop after the receipt and before any row: the flag and the receipt are there, no row is. Importing the same
    /// file again adds exactly the recorded rows and removes the receipt and the flag.
    func testAStopAfterTheReceiptIsFinishedByImportingTheSameFileAgain() throws {
        let store = try medicationStore()
        let data = try fullExport()
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try store.recordMedicationRestoreReceipt(digest, planned: MedicationRestoreSet(medications: [vial, pen], doses: fileDoses))

        let summary = try importFile(data, into: store, journal: journal)

        XCTAssertEqual(summary.medications, 2)
        XCTAssertEqual(summary.medicationDoses, 3)
        XCTAssertEqual(try doseIDs(store), Set(fileDoses.map(\.id)))
        XCTAssertNil(try store.medicationRestoreReceipt(digest), "a finished resume removes its receipt")
        XCTAssertNil(try journal.restoreInProgressDigest(), "a finished resume clears its flag")
    }

    /// A dose the restore wrote and the person deleted after every row was written is not added back when the same
    /// file is imported again while the flag is still set: the receipt is marked done, so the import is refused as
    /// already restored.
    func testADoseDeletedAfterTheRestoreFinishedIsNotReAdded() throws {
        let store = try medicationStore()
        let data = try fullExport()
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try store.recordMedicationRestoreReceipt(digest, planned: MedicationRestoreSet(medications: [vial, pen], doses: fileDoses))
        for medication in [vial, pen] { XCTAssertTrue(try store.writeRestoredMedication(medication, receipt: digest)) }
        for dose in fileDoses { XCTAssertTrue(try store.writeRestoredDose(dose, receipt: digest)) }
        try store.markMedicationRestoreReceiptDone(digest)
        try store.removeDose(id: fileDoses[2].id)

        XCTAssertThrowsError(try importFile(data, into: store, journal: journal)) { error in
            guard case JournalImportError.alreadyRestored = error else {
                return XCTFail("expected alreadyRestored, got \(error)")
            }
        }
        XCTAssertFalse(try doseIDs(store).contains(fileDoses[2].id), "a dose the person deleted must not come back")
    }

    /// A receipt damaged between two runs no longer stops the file: the next import removes it, plans the rows again
    /// from the device, adds what is missing, and clears the receipt and the flag.
    func testAnUnreadableReceiptIsRemovedAndTheResumeFinishes() throws {
        let store = try medicationStore()
        let data = try fullExport()
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try store.recordMedicationRestoreReceipt(digest, planned: MedicationRestoreSet(medications: [vial, pen], doses: fileDoses))
        XCTAssertTrue(try store.writeRestoredMedication(vial, receipt: digest))
        try store.writeUnreadableReceiptForTesting(digest)
        XCTAssertThrowsError(try store.medicationRestoreReceiptDone(digest)) { error in
            XCTAssertEqual(error as? MedicationStoreError, .unreadableReceipt)
        }

        let summary = try importFile(data, into: store, journal: journal)

        XCTAssertEqual(try store.medications(), [pen, vial])
        XCTAssertEqual(try doseIDs(store), Set(fileDoses.map(\.id)))
        XCTAssertEqual(summary.medications, 1, "the vial the stopped run wrote is held, so only the pen is new")
        XCTAssertEqual(summary.medicationDoses, 3)
        XCTAssertNil(try store.medicationRestoreReceiptDone(digest), "the receipt is gone")
        XCTAssertNil(try journal.restoreInProgressDigest(), "the flag is cleared")
    }

    /// A receipt damaged during the restore leaves the undo unable to read what it wrote, so the flag stays. That is not
    /// a dead end: importing the same file again finishes the restore.
    func testAReceiptDamagedDuringTheRestoreDoesNotStopTheRetry() throws {
        let base = try medicationStore()
        let sameJournal = try journal()
        let data = try fullExport()
        let digest = JournalImporter.fileDigest(data)
        var writes = 0
        let store = ScriptedMedicationStore(base: base) { _, base in
            writes += 1
            if writes == 4 {
                try base.writeUnreadableReceiptForTesting(digest)
                throw JournalImportError.corrupt("stopped")
            }
        }
        XCTAssertThrowsError(try importFile(data, into: store, journal: sameJournal)) { error in
            guard case JournalImportError.partialRestore = error else { return XCTFail("expected partialRestore, got \(error)") }
        }
        XCTAssertEqual(try sameJournal.restoreInProgressDigest(), digest, "rows of unknown origin keep the flag")

        _ = try importFile(data, into: base, journal: sameJournal)

        XCTAssertEqual(try base.medications(), [pen, vial])
        XCTAssertEqual(try doseIDs(base), Set(fileDoses.map(\.id)))
        XCTAssertNil(try base.medicationRestoreReceiptDone(digest))
        XCTAssertNil(try sameJournal.restoreInProgressDigest())
    }

    /// A medication renamed on the device between two runs gets none of the file's doses on resume: the receipt that
    /// still names them is dropped and the rows are planned again under the id and name rule.
    func testAResumeWritesNoDoseOntoAMedicationRenamedSinceTheStop() throws {
        let store = try medicationStore()
        let data = try fullExport()
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try store.recordMedicationRestoreReceipt(digest, planned: MedicationRestoreSet(medications: [vial, pen], doses: fileDoses))
        XCTAssertTrue(try store.writeRestoredMedication(vial, receipt: digest))
        let renamed = Medication(id: vial.id, name: "Example other", unit: .mg, scheduleDays: 7)
        try store.saveMedication(renamed)

        let summary = try importFile(data, into: store, journal: journal)

        XCTAssertEqual(try store.medications(), [renamed, pen], "ordered by name: the renamed vial comes first")
        XCTAssertEqual(try store.doses(of: vial.id), [], "no dose lands on the renamed medication")
        XCTAssertEqual(try doseIDs(store), [fileDoses[2].id])
        XCTAssertEqual(summary.medications, 2, "the vial the stopped run wrote is still counted")
        XCTAssertEqual(summary.medicationDoses, 1)
        XCTAssertNil(try store.medicationRestoreReceiptDone(digest))
        XCTAssertNil(try journal.restoreInProgressDigest())
    }

    /// A replan after a rename keeps the rows earlier runs wrote in the ledger, so an undo still removes them.
    func testAnUndoAfterARenamedResumeRemovesWhatTheStoppedRunWrote() throws {
        let base = try medicationStore()
        let data = try fullExport()
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try base.recordMedicationRestoreReceipt(digest, planned: MedicationRestoreSet(medications: [vial, pen], doses: fileDoses))
        XCTAssertTrue(try base.writeRestoredMedication(vial, receipt: digest))
        XCTAssertTrue(try base.writeRestoredMedication(pen, receipt: digest))
        let renamed = Medication(id: vial.id, name: "Example other", unit: .mg, scheduleDays: 7)
        try base.saveMedication(renamed)
        let store = ScriptedMedicationStore(base: base) { _, _ in throw JournalImportError.corrupt("stopped") }
        XCTAssertThrowsError(try importFile(data, into: store, journal: journal))
        XCTAssertEqual(
            try base.medicationRestoreReceipt(digest), MedicationRestoreSet(doses: [fileDoses[2]]),
            "only the pen's dose is left to write")

        let written = try base.medicationRestoreWritten(digest)
        XCTAssertEqual(written, MedicationRestoreSet(medications: [vial, pen]), "the ledger keeps both medications")
        XCTAssertFalse(JournalImporter.undoMedications(written, in: base, receipt: digest), "the renamed vial is kept")

        XCTAssertEqual(try base.medications(), [renamed], "the pen the stopped run wrote is removed")
    }

    /// An undo of a row the person already deleted counts it as undone and does not queue it again, so a retry from the
    /// same receipt does not bring it back.
    func testAnUndoOfARowAlreadyGoneDoesNotQueueItAgain() throws {
        let store = try medicationStore()
        try store.recordMedicationRestoreReceipt("r", planned: MedicationRestoreSet(medications: [vial], doses: [fileDoses[1]]))
        XCTAssertTrue(try store.writeRestoredMedication(vial, receipt: "r"))
        XCTAssertTrue(try store.writeRestoredDose(fileDoses[1], receipt: "r"))
        try store.markMedicationRestoreReceiptDone("r")
        try store.removeMedication(id: vial.id)

        XCTAssertTrue(try store.undoRestoredDose(fileDoses[1], receipt: "r"))
        XCTAssertTrue(try store.undoRestoredMedication(vial, receipt: "r"))

        XCTAssertEqual(try store.medicationRestoreReceipt("r"), MedicationRestoreSet(), "nothing deleted is queued again")
        XCTAssertEqual(try store.medicationRestoreWritten("r"), MedicationRestoreSet(), "and nothing is left as written")
        XCTAssertEqual(try store.medicationRestoreReceiptDone("r"), true)
    }

    func testAWrittenRowLeavesTheReceiptAndJoinsItsLedger() throws {
        let store = try medicationStore()
        try store.recordMedicationRestoreReceipt("r", planned: MedicationRestoreSet(medications: [vial], doses: [fileDoses[1]]))
        try store.saveMedication(Medication(name: "Example pen", unit: .units))

        XCTAssertTrue(try store.writeRestoredMedication(vial, receipt: "r"))
        XCTAssertFalse(try store.writeRestoredMedication(vial, receipt: "r"), "a held id is never written over")
        XCTAssertFalse(try store.writeRestoredMedication(pen, receipt: "r"), "a held name is never written over")
        XCTAssertTrue(try store.writeRestoredDose(fileDoses[1], receipt: "r"))
        XCTAssertFalse(try store.writeRestoredDose(fileDoses[2], receipt: "r"), "a dose whose medication is not stored")

        XCTAssertEqual(try store.medicationRestoreReceipt("r"), MedicationRestoreSet(), "written rows leave the plan")
        XCTAssertEqual(
            try store.medicationRestoreWritten("r"), MedicationRestoreSet(medications: [vial], doses: [fileDoses[1]]))
        XCTAssertEqual(try store.medicationRestoreReceiptDone("r"), false)
        try store.markMedicationRestoreReceiptDone("r")
        XCTAssertEqual(try store.medicationRestoreReceiptDone("r"), true)
        try store.removeMedicationRestoreReceipt("r")
        XCTAssertNil(try store.medicationRestoreReceiptDone("r"))
    }

    func testAFailedWriteRollsBackOnlyWhatTheRestoreWrote() throws {
        let base = try medicationStore()
        try base.saveMedication(tablet)
        let own = dose(9, tablet)
        try base.saveDose(own)
        let data = try fullExport()
        var writes = 0
        let store = ScriptedMedicationStore(base: base) { _, _ in
            writes += 1
            if writes == 4 { throw JournalImportError.corrupt("stopped") }
        }

        XCTAssertThrowsError(try importFile(data, into: store)) { error in
            XCTAssertEqual(error as? JournalImportError, .rolledBack)
        }

        XCTAssertEqual(try base.medications(), [tablet], "the person's own medication stays, the restored ones go")
        XCTAssertEqual(try base.allDoses(), [own])
        XCTAssertNil(try base.medicationRestoreReceipt(JournalImporter.fileDigest(data)))
    }

    func testADoseThePersonLoggedDuringTheRestoreSurvivesRollback() throws {
        let base = try medicationStore()
        let data = try fullExport()
        let logged = MedicationDose(
            medicationID: vial.id, takenAt: Date(timeIntervalSince1970: 1_776_900_000), timeZoneIdentifier: "UTC",
            amount: 1, unit: .mg)
        var writes = 0
        let store = ScriptedMedicationStore(base: base) { _, base in
            writes += 1
            // Both medications are written; the person logs a dose of the restored vial, then a write fails.
            if writes == 3 { try base.saveDose(logged) }
            if writes == 4 { throw JournalImportError.corrupt("stopped") }
        }

        XCTAssertThrowsError(try importFile(data, into: store))

        XCTAssertTrue(try doseIDs(base).contains(logged.id), "a dose the person logged is never removed by an undo")
        XCTAssertTrue(try base.medications().contains(vial), "a medication with the person's dose stays")
        XCTAssertFalse(try base.medications().contains(pen), "the restored medication with no dose of the person's goes")
    }

    func testARetryAfterAPartialRollbackRestoresWhatTheUndoRemoved() throws {
        let base = try medicationStore()
        let sameJournal = try journal()
        let data = try fullExport()
        let logged = MedicationDose(
            medicationID: vial.id, takenAt: Date(timeIntervalSince1970: 1_776_900_000), timeZoneIdentifier: "UTC",
            amount: 1, unit: .mg)
        var writes = 0
        let store = ScriptedMedicationStore(base: base) { _, base in
            writes += 1
            if writes == 3 { try base.saveDose(logged) }
            if writes == 4 { throw JournalImportError.corrupt("stopped") }
        }
        XCTAssertThrowsError(try importFile(data, into: store, journal: sameJournal))
        XCTAssertFalse(try base.medications().contains(pen), "the undo removed the restored pen")

        _ = try importFile(data, into: base, journal: sameJournal)

        XCTAssertEqual(try base.medications(), [pen, vial])
        XCTAssertEqual(try doseIDs(base), Set(fileDoses.map(\.id)).union([logged.id]), "the retry restores what the undo removed")
        XCTAssertNil(try base.medicationRestoreReceipt(JournalImporter.fileDigest(data)))
    }

    func testALongLogIsRestoredInBatchesAndEveryDoseArrives() throws {
        let store = try medicationStore()
        let many = (0..<600).map { index in
            MedicationDose(
                medicationID: vial.id, takenAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 3_600)),
                timeZoneIdentifier: "UTC", amount: 2, unit: .mg)
        }
        let data = try medicationsExport([vial], many)

        let summary = try importFile(data, into: store)

        XCTAssertEqual(summary.medicationDoses, 600)
        XCTAssertEqual(try doseIDs(store), Set(many.map(\.id)))
        XCTAssertNil(try store.medicationRestoreReceipt(JournalImporter.fileDigest(data)))
    }

    func testAnUndoNeverRemovesAMedicationThatHoldsADose() throws {
        let store = try medicationStore()
        try store.saveMedication(vial)
        let own = dose(9, vial)
        try store.saveDose(own)

        XCTAssertFalse(try store.undoRestoredMedication(vial, receipt: nil))
        XCTAssertTrue(try store.undoRestoredDose(dose(8, vial), receipt: nil), "a dose already gone counts as undone")

        XCTAssertEqual(try store.medications(), [vial])
        XCTAssertEqual(try store.allDoses(), [own])
    }

    func testUndoRemovesOnlyTheRecordedRowsThatAreUnchanged() throws {
        let store = try medicationStore()
        for medication in [vial, pen, tablet] { try store.saveMedication(medication) }
        let changed = dose(1, vial, amount: 3)
        for dose in [changed, fileDoses[1], fileDoses[2]] { try store.saveDose(dose) }

        let clean = JournalImporter.undoMedications(
            MedicationRestoreSet(medications: [vial, pen], doses: fileDoses), in: store)

        XCTAssertFalse(clean, "a row the person changed is left, so the undo is not clean")
        XCTAssertEqual(try store.allDoses(), [changed], "the changed dose is the person's now")
        XCTAssertEqual(try store.medications(), [tablet, vial], "the medication holding that dose stays")
    }
}

/// A medication store over a real one that runs `onWrite` before each restored medication or dose is written, so a
/// test can fail a write or change the store in the middle of a restore.
private final class ScriptedMedicationStore: MedicationStore, @unchecked Sendable {
    let base: SwiftDataMedicationStore
    let onWrite: (UUID, SwiftDataMedicationStore) throws -> Void

    init(base: SwiftDataMedicationStore, onWrite: @escaping (UUID, SwiftDataMedicationStore) throws -> Void) {
        self.base = base
        self.onWrite = onWrite
    }

    func medications() throws -> [Medication] { try base.medications() }
    func allDoses() throws -> [MedicationDose] { try base.allDoses() }
    func doses(of medicationID: UUID) throws -> [MedicationDose] { try base.doses(of: medicationID) }
    func saveMedication(_ medication: Medication) throws { try base.saveMedication(medication) }
    func removeMedication(id: UUID) throws { try base.removeMedication(id: id) }
    func saveDose(_ dose: MedicationDose) throws { try base.saveDose(dose) }
    func removeDose(id: UUID) throws { try base.removeDose(id: id) }

    func recordMedicationRestoreReceipt(_ receipt: String, planned: MedicationRestoreSet) throws {
        try base.recordMedicationRestoreReceipt(receipt, planned: planned)
    }
    func medicationRestoreReceipt(_ receipt: String) throws -> MedicationRestoreSet? {
        try base.medicationRestoreReceipt(receipt)
    }
    func replanMedicationRestoreReceipt(_ receipt: String, planned: MedicationRestoreSet) throws {
        try base.replanMedicationRestoreReceipt(receipt, planned: planned)
    }
    func removeMedicationRestoreReceipt(_ receipt: String) throws { try base.removeMedicationRestoreReceipt(receipt) }
    func medicationRestoreReceiptDone(_ receipt: String) throws -> Bool? { try base.medicationRestoreReceiptDone(receipt) }
    func markMedicationRestoreReceiptDone(_ receipt: String) throws { try base.markMedicationRestoreReceiptDone(receipt) }
    func writeRestoredMedication(_ medication: Medication, receipt: String) throws -> Bool {
        try onWrite(medication.id, base)
        return try base.writeRestoredMedication(medication, receipt: receipt)
    }
    func writeRestoredDose(_ dose: MedicationDose, receipt: String) throws -> Bool {
        try onWrite(dose.id, base)
        return try base.writeRestoredDose(dose, receipt: receipt)
    }
    func medicationRestoreWritten(_ receipt: String) throws -> MedicationRestoreSet {
        try base.medicationRestoreWritten(receipt)
    }
    func undoRestoredDose(_ dose: MedicationDose, receipt: String?) throws -> Bool {
        try base.undoRestoredDose(dose, receipt: receipt)
    }
    func undoRestoredMedication(_ medication: Medication, receipt: String?) throws -> Bool {
        try base.undoRestoredMedication(medication, receipt: receipt)
    }
}
