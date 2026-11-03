import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A confirmed clear that reaches the erase withdraws the Undo offer whether the erase succeeds or fails, because a
/// failed erase may already have removed the dose Undo names. A clear that keeps a log that reads again keeps it.
@MainActor
final class MedicationLogClearUndoTests: XCTestCase {
    private let medication = Medication(name: "Example vial", unit: .mL)

    /// A model whose log has a dose just logged, with Undo offered, and whose store then stops reading.
    private func modelWithUndoThenUnreadable(_ store: UndoClearMedicationStore) -> MedicationLogViewModel {
        let model = MedicationLogViewModel(store: store, preferences: InMemoryDisplayPreferences(), eraser: store)
        model.load()
        XCTAssertNil(model.logDose(
            medicationID: medication.id, amountText: "2.5", takenAt: Date(timeIntervalSince1970: 1_776_159_000),
            siteText: "", noteText: ""))
        XCTAssertNotNil(model.undoText)
        store.failsReads = true
        model.load()
        XCTAssertTrue(model.canClear)
        return model
    }

    func testAFailedEraseThatRemovedTheDosesWithdrawsUndo() {
        let store = UndoClearMedicationStore(medications: [medication])
        store.eraseOutcome = .removesRowsThenFails
        let model = modelWithUndoThenUnreadable(store)

        model.clearLog()

        XCTAssertEqual(model.errorMessage, "Could not clear the medication log.")
        XCTAssertNil(model.undoText, "Undo never names a dose the erase may have removed")
        model.undoLastDose()
        XCTAssertEqual(store.removeDoseCount, 0)
    }

    func testAFailedEraseThatChangedNothingAlsoWithdrawsUndo() {
        let store = UndoClearMedicationStore(medications: [medication])
        store.eraseOutcome = .failsWithoutChange
        let model = modelWithUndoThenUnreadable(store)

        model.clearLog()

        XCTAssertNil(model.undoText)
        XCTAssertTrue(model.canClear)
    }

    func testALogThatReadsAgainKeepsUndo() {
        let store = UndoClearMedicationStore(medications: [medication])
        let model = modelWithUndoThenUnreadable(store)
        store.failsReads = false

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 0)
        XCTAssertNotNil(model.undoText, "nothing was erased, so the dose can still be undone")
    }
}

/// A medication store that is also its own eraser, whose reads can be made to fail and whose erase can succeed,
/// remove everything and then report a failure, or report a failure without changing anything.
private final class UndoClearMedicationStore: MedicationStore, JournalErasing, @unchecked Sendable {
    enum EraseOutcome {
        case succeeds, removesRowsThenFails, failsWithoutChange
    }

    private struct EraseFailed: Error {}

    private var base: InMemoryMedicationStore
    var failsReads = false
    var eraseOutcome = EraseOutcome.succeeds
    private(set) var eraseCount = 0
    private(set) var removeDoseCount = 0

    init(medications: [Medication]) {
        base = InMemoryMedicationStore(medications: medications)
    }

    let erasureName = "medications"

    func eraseAll() throws {
        eraseCount += 1
        switch eraseOutcome {
        case .succeeds:
            base = InMemoryMedicationStore()
            failsReads = false
        case .removesRowsThenFails:
            base = InMemoryMedicationStore()
            failsReads = false
            throw EraseFailed()
        case .failsWithoutChange:
            throw EraseFailed()
        }
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

    func removeDose(id: UUID) throws {
        removeDoseCount += 1
        try base.removeDose(id: id)
    }
}
