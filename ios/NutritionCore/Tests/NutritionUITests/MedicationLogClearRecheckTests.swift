import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Clearing the Medication log reads it again first and erases only when it still cannot be read, so a read that
/// failed for a passing reason (a locked or busy file) never costs the person their log.
@MainActor
final class MedicationLogClearRecheckTests: XCTestCase {
    private func makeModel(_ store: RecheckMedicationStore) -> MedicationLogViewModel {
        MedicationLogViewModel(store: store, preferences: InMemoryDisplayPreferences(), eraser: store)
    }

    func testALogThatReadsAgainWhenThePersonConfirmsIsNotErased() throws {
        let store = RecheckMedicationStore(
            InMemoryMedicationStore(medications: [Medication(name: "Example vial", unit: .mL)]))
        store.failsReads = true
        let model = makeModel(store)
        model.load()
        XCTAssertTrue(model.canClear)
        store.failsReads = false

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 0, "a log that reads again is never erased")
        XCTAssertFalse(model.canClear)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows.map(\.name), ["Example vial"])
        XCTAssertEqual(try store.medications().count, 1)
    }

    func testALogThatStillCannotBeReadIsErased() {
        let store = RecheckMedicationStore(
            InMemoryMedicationStore(medications: [Medication(name: "Example vial", unit: .mL)]))
        store.failsReads = true
        let model = makeModel(store)
        model.load()

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 1)
        XCTAssertFalse(model.canClear)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows, [])
    }
}

/// A medication store that is also its own eraser, whose reads can be made to fail. A successful erase removes
/// everything and lets the store read again.
private final class RecheckMedicationStore: MedicationStore, JournalErasing, @unchecked Sendable {
    private var base: InMemoryMedicationStore
    var failsReads = false
    private(set) var eraseCount = 0

    init(_ base: InMemoryMedicationStore) {
        self.base = base
    }

    let erasureName = "medications"

    func eraseAll() throws {
        eraseCount += 1
        base = InMemoryMedicationStore()
        failsReads = false
    }

    func medications() throws -> [Medication] {
        if failsReads { throw CocoaError(.fileReadCorruptFile) }
        return try base.medications()
    }

    func allDoses() throws -> [MedicationDose] {
        if failsReads { throw CocoaError(.fileReadCorruptFile) }
        return try base.allDoses()
    }

    func doses(of medicationID: UUID) throws -> [MedicationDose] {
        if failsReads { throw CocoaError(.fileReadCorruptFile) }
        return try base.doses(of: medicationID)
    }

    func saveMedication(_ medication: Medication) throws { try base.saveMedication(medication) }
    func removeMedication(id: UUID) throws { try base.removeMedication(id: id) }
    func saveDose(_ dose: MedicationDose) throws { try base.saveDose(dose) }
    func removeDose(id: UUID) throws { try base.removeDose(id: id) }
}
