import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// What the Medication log shows after the person confirms the clear: a notice when the log reads again and nothing
/// was cleared, and the log as it now reads when the erase reports a failure: a log that reads says the clear did
/// not finish, and one that still cannot be read says it could not be cleared.
@MainActor
final class MedicationLogClearOutcomeTests: XCTestCase {
    private func makeModel(_ store: OutcomeMedicationStore) -> MedicationLogViewModel {
        MedicationLogViewModel(store: store, preferences: InMemoryDisplayPreferences(), eraser: store)
    }

    private func unreadableStore() -> OutcomeMedicationStore {
        let store = OutcomeMedicationStore(
            InMemoryMedicationStore(medications: [Medication(name: "Example vial", unit: .mL)]))
        store.failsReads = true
        return store
    }

    func testALogThatReadsAgainSaysNothingWasCleared() {
        let store = unreadableStore()
        let model = makeModel(store)
        model.load()
        XCTAssertNil(model.clearNotice)
        store.failsReads = false

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 0)
        XCTAssertEqual(model.clearNotice, "The medication log can be read again, so nothing was cleared.")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows.map(\.name), ["Example vial"])
    }

    func testTheNoticeGoesAwayOnTheNextRead() {
        let store = unreadableStore()
        let model = makeModel(store)
        model.load()
        store.failsReads = false
        model.clearLog()
        XCTAssertNotNil(model.clearNotice)

        model.load()

        XCTAssertNil(model.clearNotice)
    }

    func testAClearThatErasesShowsNoNotice() {
        let store = unreadableStore()
        let model = makeModel(store)
        model.load()

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 1)
        XCTAssertNil(model.clearNotice)
        XCTAssertEqual(model.rows, [])
    }

    func testAFailedEraseThatRemovedTheRowsSaysTheClearDidNotFinish() {
        let store = unreadableStore()
        store.eraseOutcome = .removesRowsThenFails
        let model = makeModel(store)
        model.load()

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 1)
        XCTAssertEqual(model.rows, [], "the screen shows the log as it now reads, not the rows from before")
        XCTAssertEqual(model.errorMessage, "The clear did not finish. The log shows what this device holds now.",
                       "an empty log that reads is not described as one that could not be cleared")
        XCTAssertFalse(model.canClear, "a log that reads now is not offered for clearing again")
        XCTAssertNil(model.clearNotice)
    }

    func testAFailedEraseThatChangedNothingKeepsTheOffer() {
        let store = unreadableStore()
        store.eraseOutcome = .failsWithoutChange
        let model = makeModel(store)
        model.load()

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 1)
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.errorMessage, "Could not clear the medication log.")
        XCTAssertTrue(model.canClear)
        XCTAssertNil(model.clearNotice)
    }
}

/// A medication store that is also its own eraser, whose reads can be made to fail and whose erase can succeed,
/// remove everything and then report a failure, or report a failure without changing anything.
private final class OutcomeMedicationStore: MedicationStore, JournalErasing, @unchecked Sendable {
    enum EraseOutcome {
        case succeeds, removesRowsThenFails, failsWithoutChange
    }

    private struct EraseFailed: Error {}

    private var base: InMemoryMedicationStore
    var failsReads = false
    var eraseOutcome = EraseOutcome.succeeds
    private(set) var eraseCount = 0

    init(_ base: InMemoryMedicationStore) {
        self.base = base
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
    func removeDose(id: UUID) throws { try base.removeDose(id: id) }
}
