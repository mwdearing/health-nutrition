import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Medication log when its store cannot be read: the log says so and offers to clear itself, and clearing erases
/// only the medication store, after the person confirms. A log that reads fine never offers it. Also: a dose whose own
/// day is after today on this device shows neither a days-since line nor a schedule standing line.
@MainActor
final class MedicationLogRepairTests: XCTestCase {
    /// 2026-04-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let utc = TimeZone(identifier: "UTC")!

    private func makeModel(_ store: MedicationStore, eraser: JournalErasing? = nil) -> MedicationLogViewModel {
        let fixed = now
        let zone = utc
        return MedicationLogViewModel(
            store: store, preferences: InMemoryDisplayPreferences(), now: { fixed }, timeZone: { zone },
            eraser: eraser)
    }

    private func weekly() -> Medication {
        Medication(name: "Example weekly injection", unit: .mg, scheduleDays: 7)
    }

    // MARK: - Offering the clear

    func testAFailedReadOffersToClearTheLog() {
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [weekly()]))
        store.failsReads = true
        let model = makeModel(store, eraser: store)
        model.load()
        XCTAssertEqual(model.errorMessage, "Could not read the medication log.")
        XCTAssertTrue(model.canClear)
        XCTAssertEqual(model.rows, [])
    }

    func testALogThatReadsFineOffersNoClear() {
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [weekly()]))
        let model = makeModel(store, eraser: store)
        model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canClear)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testWithoutAnEraserAFailedReadOffersNoClear() {
        let model = makeModel(InMemoryMedicationStore(medications: [weekly()], failReads: true))
        model.load()
        XCTAssertEqual(model.errorMessage, "Could not read the medication log.")
        XCTAssertFalse(model.canClear)
    }

    func testTheOfferGoesWhenTheLogReadsAgain() {
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [weekly()]))
        store.failsReads = true
        let model = makeModel(store, eraser: store)
        model.load()
        XCTAssertTrue(model.canClear)
        store.failsReads = false
        model.load()
        XCTAssertFalse(model.canClear)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows.count, 1)
    }

    // MARK: - Clearing

    func testClearingErasesTheMedicationStoreAndReadsAgain() throws {
        let medication = weekly()
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [medication]))
        let model = makeModel(store, eraser: store)
        model.load()
        XCTAssertNil(model.logDose(
            medicationID: medication.id, amountText: "2.5", takenAt: now, siteText: "", noteText: ""))
        XCTAssertNotNil(model.undoText)
        store.failsReads = true
        model.load()
        XCTAssertTrue(model.canClear)

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canClear)
        XCTAssertNil(model.undoText, "the Undo offer named a dose the clear removed")
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.archivedRows, [])
        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
    }

    func testAFailedClearSaysSoAndKeepsTheOffer() {
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [weekly()]))
        store.failsReads = true
        store.failsErase = true
        let model = makeModel(store, eraser: store)
        model.load()

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 1)
        XCTAssertEqual(model.errorMessage, "Could not clear the medication log.")
        XCTAssertTrue(model.canClear)
        store.failsErase = false
        model.clearLog()
        XCTAssertEqual(store.eraseCount, 2)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canClear)
    }

    func testClearingDoesNothingWhileTheLogReadsFine() throws {
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [weekly()]))
        let model = makeModel(store, eraser: store)
        model.load()

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 0, "a log that reads fine is never cleared from this screen")
        XCTAssertEqual(try store.medications().count, 1)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testClearingBeforeAnyReadDoesNothing() {
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [weekly()]))
        store.failsReads = true
        let model = makeModel(store, eraser: store)

        model.clearLog()

        XCTAssertEqual(store.eraseCount, 0, "only a read that failed on screen offers the clear")
    }

    func testReplacingTheStoresReadsAgainAndWithdrawsTheOffer() {
        let store = ClearableMedicationStore(InMemoryMedicationStore(medications: [weekly()]))
        store.failsReads = true
        let model = makeModel(store, eraser: store)
        model.load()
        XCTAssertTrue(model.canClear)
        store.failsReads = false

        model.storesWereReplaced()

        XCTAssertFalse(model.canClear)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(store.eraseCount, 0)
    }

    // MARK: - A dose after today here

    func testADoseWhoseOwnDayIsAfterTodayHereHasNoStandingLine() {
        let medication = weekly()
        // 2026-04-15 11:00 UTC is 2026-04-16 01:00 in a zone fourteen hours ahead.
        let dose = MedicationDose(
            medicationID: medication.id, takenAt: now.addingTimeInterval(-3_600),
            timeZoneIdentifier: "Pacific/Kiritimati", amount: Decimal(string: "2.5")!, unit: .mg)
        let model = makeModel(InMemoryMedicationStore(medications: [medication], doses: [dose]))
        model.load()
        let row = model.rows.first
        XCTAssertEqual(row?.lastDoseText, "Last dose 2.5 mg on Apr 16, 2026 at 1:00 AM")
        XCTAssertEqual(row?.scheduleText, "Every 7 days")
        XCTAssertNil(row?.daysSinceText)
        XCTAssertNil(row?.statusText)
    }

    func testADoseEarlierTodayStillShowsItsStandingLine() {
        let medication = weekly()
        let dose = MedicationDose(
            medicationID: medication.id, takenAt: now.addingTimeInterval(-3_600), timeZoneIdentifier: "UTC",
            amount: Decimal(string: "2.5")!, unit: .mg)
        let model = makeModel(InMemoryMedicationStore(medications: [medication], doses: [dose]))
        model.load()
        XCTAssertEqual(model.rows.first?.daysSinceText, "Today")
        XCTAssertEqual(model.rows.first?.statusText, "Next by your schedule: Apr 22, 2026")
    }
}

/// A medication store that is also its own eraser, whose reads and erase can be made to fail. A successful erase
/// removes everything and lets the store read again, as the SwiftData store's erase replaces a damaged file.
private final class ClearableMedicationStore: MedicationStore, JournalErasing, @unchecked Sendable {
    private var base: InMemoryMedicationStore
    var failsReads = false
    var failsErase = false
    private(set) var eraseCount = 0

    init(_ base: InMemoryMedicationStore) {
        self.base = base
    }

    let erasureName = "medications"

    func eraseAll() throws {
        eraseCount += 1
        if failsErase { throw CocoaError(.fileWriteNoPermission) }
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
