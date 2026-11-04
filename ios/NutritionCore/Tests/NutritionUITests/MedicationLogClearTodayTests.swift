import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A confirmed clear on a log whose reads failed and then succeed, but whose day cannot be read, says nothing
/// and erases nothing. The log did read, so the "can be read again" notice would be wrong; the day is not a
/// store read, so the clear is not offered either.
@MainActor
final class MedicationLogClearTodayTests: XCTestCase {
    func testAClearWhoseDayCannotBeReadSaysNothingAndErasesNothing() throws {
        let store = TodayMedicationStore(
            InMemoryMedicationStore(medications: [Medication(name: "Example vial", unit: .mL)]))
        store.failsReads = true
        let model = MedicationLogViewModel(store: store, preferences: InMemoryDisplayPreferences(), eraser: store)
        model.load()
        XCTAssertTrue(model.canClear)
        store.failsReads = false
        model.dayOverride = { nil }

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 0, "a log that cannot be dated is never erased")
        XCTAssertNil(model.clearNotice, "the log did not read, so the notice would be false")
        XCTAssertFalse(model.canClear)
        XCTAssertEqual(model.errorMessage, "Could not read the medication log.")
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(try store.medications().map(\.name), ["Example vial"])
    }
}

/// A medication store that is also its own eraser, whose reads can be made to fail. A successful erase removes
/// everything and lets the store read again.
private final class TodayMedicationStore: MedicationStore, JournalErasing, @unchecked Sendable {
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
