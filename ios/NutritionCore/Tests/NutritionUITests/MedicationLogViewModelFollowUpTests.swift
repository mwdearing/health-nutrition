import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Medication log's review follow-ups: a failed Undo can be tried again, replacing the stores forgets the
/// Undo offer, a dose after today here has no days-since line, and amounts group thousands with a comma.
@MainActor
final class MedicationLogViewModelFollowUpTests: XCTestCase {
    /// 2026-04-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let utc = TimeZone(identifier: "UTC")!

    private func makeModel(_ store: MedicationStore) -> MedicationLogViewModel {
        let fixed = now
        let zone = utc
        return MedicationLogViewModel(
            store: store, preferences: InMemoryDisplayPreferences(), now: { fixed }, timeZone: { zone })
    }

    private func weekly() -> Medication {
        Medication(name: "Example weekly injection", unit: .mg, scheduleDays: 7)
    }

    private func log(_ model: MedicationLogViewModel, _ medication: Medication, amount: String = "2.5") -> String? {
        model.logDose(medicationID: medication.id, amountText: amount, takenAt: now, siteText: "", noteText: "")
    }

    // MARK: - Undo

    func testAFailedUndoKeepsTheOfferSoItCanBeTriedAgain() throws {
        let medication = weekly()
        let store = RemovalFailingMedicationStore(InMemoryMedicationStore(medications: [medication]))
        let model = makeModel(store)
        model.load()
        XCTAssertNil(log(model, medication))

        store.failsRemovals = true
        model.undoLastDose()
        XCTAssertEqual(model.errorMessage, "Could not undo the dose.")
        XCTAssertEqual(model.undoText, "Logged 2.5 mg of Example weekly injection")
        XCTAssertEqual(try store.allDoses().count, 1)

        store.failsRemovals = false
        model.undoLastDose()
        XCTAssertNil(model.undoText)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try store.allDoses().count, 0)
    }

    func testReplacingTheStoresForgetsTheUndoOffer() throws {
        let medication = weekly()
        let store = InMemoryMedicationStore(medications: [medication])
        let model = makeModel(store)
        model.load()
        XCTAssertNil(log(model, medication))

        model.storesWereReplaced()
        XCTAssertNil(model.undoText)
        // Undo after the replacement removes nothing: the offer named a dose from before it.
        model.undoLastDose()
        XCTAssertEqual(try store.allDoses().count, 1)
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 2.5 mg on Apr 15, 2026 at 12:00 PM")
    }

    // MARK: - Days since

    func testADoseWhoseOwnDayIsAfterTodayHereHasNoDaysSinceLine() {
        let medication = weekly()
        // 2026-04-15 11:00 UTC is 2026-04-16 01:00 in a zone fourteen hours ahead.
        let dose = MedicationDose(
            medicationID: medication.id, takenAt: now.addingTimeInterval(-3_600),
            timeZoneIdentifier: "Pacific/Kiritimati", amount: Decimal(string: "2.5")!, unit: .mg)
        let model = makeModel(InMemoryMedicationStore(medications: [medication], doses: [dose]))
        model.load()
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 2.5 mg on Apr 16, 2026 at 1:00 AM")
        XCTAssertNil(model.rows.first?.daysSinceText)
    }

    // MARK: - Amounts

    func testAThousandReadsWithACommaInTheUndoAndLastDoseLines() {
        let medication = weekly()
        let model = makeModel(InMemoryMedicationStore(medications: [medication]))
        model.load()
        XCTAssertNil(log(model, medication, amount: "1000"))
        XCTAssertEqual(model.undoText, "Logged 1,000 mg of Example weekly injection")
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 1,000 mg on Apr 15, 2026 at 12:00 PM")
    }

    func testDoseAmountsKeepTheirDecimalsAndGroupOnlyThousands() {
        XCTAssertEqual(MedicationLogViewModel.doseAmountText(Decimal(string: "0.125")!), "0.125")
        XCTAssertEqual(MedicationLogViewModel.doseAmountText(Decimal(string: "999.5")!), "999.5")
        XCTAssertEqual(MedicationLogViewModel.doseAmountText(Decimal(string: "1000")!), "1,000")
        XCTAssertEqual(MedicationLogViewModel.doseAmountText(Decimal(string: "1234.75")!), "1,234.75")
    }
}

/// A medication store whose dose removal can be made to fail, so a failed Undo can be tried.
private final class RemovalFailingMedicationStore: MedicationStore, @unchecked Sendable {
    private let base: InMemoryMedicationStore
    var failsRemovals = false

    init(_ base: InMemoryMedicationStore) {
        self.base = base
    }

    func medications() throws -> [Medication] { try base.medications() }
    func allDoses() throws -> [MedicationDose] { try base.allDoses() }
    func doses(of medicationID: UUID) throws -> [MedicationDose] { try base.doses(of: medicationID) }
    func saveMedication(_ medication: Medication) throws { try base.saveMedication(medication) }
    func removeMedication(id: UUID) throws { try base.removeMedication(id: id) }
    func saveDose(_ dose: MedicationDose) throws { try base.saveDose(dose) }

    func removeDose(id: UUID) throws {
        if failsRemovals { throw CocoaError(.fileWriteNoPermission) }
        try base.removeDose(id: id)
    }
}
