import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Where the medication log is kept: the medications a person named and the doses they typed, in their
/// own store file, `medications.store`.
///
/// The rules are the same for the SwiftData store and the in-memory one, so each rule test runs against
/// both. A store never changes what was typed: a dose reads back with the amount, unit, time, zone and
/// note it was saved with, and a row that cannot be read fails the read rather than vanishing from it.
final class MedicationStoreTests: XCTestCase {
    private let penID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let dropsID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func makeStore(at url: URL? = nil) throws -> SwiftDataMedicationStore {
        let fileURL: URL
        if let url {
            fileURL = url
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            fileURL = directory.appendingPathComponent("medications.store")
        }
        let store = try SwiftDataMedicationStore(url: fileURL)
        addTeardownBlock { store.close() }
        return store
    }

    /// A fresh store of each kind, so every rule is checked against both.
    private func freshStores() throws -> [(String, MedicationStore)] {
        [("SwiftData", try makeStore()), ("in memory", InMemoryMedicationStore())]
    }

    private func amount(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private var pen: Medication {
        Medication(id: penID, name: "Example weekly injection", unit: .mg, scheduleDays: 7)
    }

    private var drops: Medication {
        Medication(id: dropsID, name: "Example daily drops", unit: .mcg)
    }

    private func dose(
        _ text: String, of medicationID: UUID? = nil, unit: MedicationUnit = .mg, at seconds: TimeInterval,
        zone: String = "America/Chicago", note: String? = nil, id: UUID = UUID()
    ) -> MedicationDose {
        MedicationDose(
            id: id, medicationID: medicationID ?? penID, takenAt: Date(timeIntervalSince1970: seconds),
            timeZoneIdentifier: zone, amount: amount(text), unit: unit, note: note)
    }

    private func storeError(_ check: () throws -> Void) -> MedicationStoreError? {
        do {
            try check()
            return nil
        } catch {
            return error as? MedicationStoreError
        }
    }

    private func isCorrupt(_ check: () throws -> Void) -> Bool {
        if case .corruptRecord? = storeError(check) { return true }
        return false
    }

    // MARK: Rules, both stores

    func testAnEmptyStoreHoldsNothing() throws {
        for (kind, store) in try freshStores() {
            XCTAssertEqual(try store.medications(), [], kind)
            XCTAssertEqual(try store.allDoses(), [], kind)
            XCTAssertEqual(try store.doses(of: penID), [], kind)
        }
    }

    func testAMedicationRoundTripsAndAnInvalidOneWritesNothing() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            XCTAssertEqual(try store.medications(), [pen], kind)

            let blank = Medication(id: dropsID, name: " ", unit: .mcg)
            XCTAssertThrowsError(try store.saveMedication(blank), kind) { error in
                XCTAssertEqual(error as? MedicationError, .nameEmpty, kind)
            }
            XCTAssertEqual(try store.medications(), [pen], kind)
        }
    }

    func testSavingTheSameIDReplacesTheMedication() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            let renamed = Medication(id: penID, name: "Example pen", unit: .mg, scheduleDays: 14, isArchived: true)
            try store.saveMedication(renamed)
            XCTAssertEqual(try store.medications(), [renamed], kind)
        }
    }

    func testNamesAreUniqueIgnoringCaseArchivedIncluded() throws {
        for (kind, store) in try freshStores() {
            let archived = Medication(id: penID, name: "Example pen", unit: .mg, isArchived: true)
            try store.saveMedication(archived)
            let twin = Medication(id: dropsID, name: "example PEN", unit: .mcg)
            XCTAssertEqual(storeError { try store.saveMedication(twin) }, .duplicateName, kind)
            XCTAssertEqual(try store.medications(), [archived], kind)
            // The same medication may keep its own name in another case.
            let recased = Medication(id: penID, name: "EXAMPLE PEN", unit: .mg, isArchived: true)
            XCTAssertNoThrow(try store.saveMedication(recased), kind)
        }
    }

    func testMedicationsAreListedByNameIgnoringCase() throws {
        for (kind, store) in try freshStores() {
            let beta = Medication(id: penID, name: "beta pen", unit: .mg)
            let alpha = Medication(id: dropsID, name: "Alpha drops", unit: .mcg)
            try store.saveMedication(beta)
            try store.saveMedication(alpha)
            XCTAssertEqual(try store.medications(), [alpha, beta], kind)
        }
    }

    func testADoseRoundTripsExactlyAsTyped() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            let typed = dose("0.125", at: 1_789_961_400, zone: "Asia/Tokyo", note: "Second pen of the box")
            try store.saveDose(typed)
            XCTAssertEqual(try store.doses(of: penID), [typed], kind)
            XCTAssertEqual(try store.allDoses(), [typed], kind)
        }
    }

    func testADoseNeedsAStoredMedicationAndItsCurrentUnit() throws {
        for (kind, store) in try freshStores() {
            XCTAssertEqual(storeError { try store.saveDose(self.dose("2.5", at: 1_789_961_400)) }, .unknownMedication, kind)
            try store.saveMedication(pen)
            XCTAssertEqual(
                storeError { try store.saveDose(self.dose("250", unit: .mcg, at: 1_789_961_400)) }, .unitMismatch, kind)
            XCTAssertEqual(try store.allDoses(), [], kind)
        }
    }

    func testAnInvalidDoseWritesNothing() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            XCTAssertThrowsError(try store.saveDose(dose("0", at: 1_789_961_400)), kind) { error in
                XCTAssertEqual(error as? MedicationError, .amountNotPositive, kind)
            }
            XCTAssertEqual(try store.allDoses(), [], kind)
        }
    }

    func testDosesReadNewestFirstAndPerMedication() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            try store.saveMedication(drops)
            let early = dose("2.5", at: 1_789_961_400)
            let late = dose("5", at: 1_790_566_200)
            let between = dose("100", of: dropsID, unit: .mcg, at: 1_790_200_000)
            try store.saveDose(early)
            try store.saveDose(between)
            try store.saveDose(late)
            XCTAssertEqual(try store.doses(of: penID), [late, early], kind)
            XCTAssertEqual(try store.doses(of: dropsID), [between], kind)
            XCTAssertEqual(try store.allDoses(), [late, between, early], kind)
        }
    }

    func testDosesAtTheSameInstantReadInIDOrder() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            let second = dose("5", at: 1_789_961_400, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
            let first = dose("2.5", at: 1_789_961_400, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            try store.saveDose(second)
            try store.saveDose(first)
            XCTAssertEqual(try store.doses(of: penID), [first, second], kind)
        }
    }

    func testSavingADoseWithTheSameIDReplacesIt() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            let id = UUID()
            try store.saveDose(dose("2.5", at: 1_789_961_400, id: id))
            let corrected = dose("5", at: 1_789_965_000, note: "Typed the wrong amount", id: id)
            try store.saveDose(corrected)
            XCTAssertEqual(try store.allDoses(), [corrected], kind)
        }
    }

    func testChangingAMedicationsUnitKeepsTheUnitOfEveryDoseAlreadyLogged() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            let inMilligrams = dose("2.5", at: 1_789_961_400)
            try store.saveDose(inMilligrams)
            try store.saveMedication(Medication(id: penID, name: pen.name, unit: .mcg, scheduleDays: 7))
            XCTAssertEqual(try store.doses(of: penID), [inMilligrams], kind)
            XCTAssertEqual(
                storeError { try store.saveDose(self.dose("2.5", at: 1_790_566_200)) }, .unitMismatch, kind)
            let inMicrograms = dose("250", unit: .mcg, at: 1_790_566_200)
            try store.saveDose(inMicrograms)
            XCTAssertEqual(try store.doses(of: penID), [inMicrograms, inMilligrams], kind)
        }
    }

    func testRemovingADoseRemovesOnlyThatDoseAndAMissingOneIsNotAnError() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            let kept = dose("2.5", at: 1_789_961_400)
            let removed = dose("5", at: 1_790_566_200)
            try store.saveDose(kept)
            try store.saveDose(removed)
            try store.removeDose(id: removed.id)
            XCTAssertEqual(try store.allDoses(), [kept], kind)
            XCTAssertNoThrow(try store.removeDose(id: UUID()), kind)
            XCTAssertNoThrow(try store.removeDose(id: removed.id), kind)
        }
    }

    func testArchivingKeepsTheMedicationAndItsDoses() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            let taken = dose("2.5", at: 1_789_961_400)
            try store.saveDose(taken)
            let archived = Medication(id: penID, name: pen.name, unit: .mg, scheduleDays: 7, isArchived: true)
            try store.saveMedication(archived)
            XCTAssertEqual(try store.medications(), [archived], kind)
            XCTAssertEqual(try store.doses(of: penID), [taken], kind)
        }
    }

    func testRemovingAMedicationRemovesItsDosesAndNoOthers() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            try store.saveMedication(drops)
            try store.saveDose(dose("2.5", at: 1_789_961_400))
            let other = dose("100", of: dropsID, unit: .mcg, at: 1_790_200_000)
            try store.saveDose(other)
            try store.removeMedication(id: penID)
            XCTAssertEqual(try store.medications(), [drops], kind)
            XCTAssertEqual(try store.doses(of: penID), [], kind)
            XCTAssertEqual(try store.allDoses(), [other], kind)
            XCTAssertNoThrow(try store.removeMedication(id: penID), kind)
            XCTAssertNoThrow(try store.removeMedication(id: UUID()), kind)
        }
    }

    // MARK: SwiftData store

    func testEverythingSurvivesClosingAndReopeningTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("medications.store")
        let archivedDrops = Medication(id: dropsID, name: "Example daily drops", unit: .mcg, isArchived: true)
        let typed = dose("0.125", at: 1_789_961_400, zone: "Asia/Tokyo", note: "Second pen of the box")
        let plain = dose("62.5", of: dropsID, unit: .mcg, at: 1_790_200_000, zone: "UTC")

        let first = try makeStore(at: url)
        try first.saveMedication(pen)
        try first.saveMedication(archivedDrops)
        try first.saveDose(typed)
        try first.saveDose(plain)
        first.close()

        let reopened = try makeStore(at: url)
        XCTAssertEqual(try reopened.medications(), [archivedDrops, pen])
        XCTAssertEqual(try reopened.allDoses(), [plain, typed])
        XCTAssertEqual(try reopened.doses(of: penID).first?.amount, amount("0.125"))
        XCTAssertNil(try reopened.medications().first?.scheduleDays)
    }

    func testEraseAllRemovesEverythingAndTheStoreStaysOpen() throws {
        let store = try makeStore()
        XCTAssertEqual(store.erasureName, "medications")
        try store.saveMedication(pen)
        try store.saveDose(dose("2.5", at: 1_789_961_400))

        try store.eraseAll()

        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
        try store.saveMedication(pen)
        XCTAssertEqual(try store.medications(), [pen])
    }

    func testAClosedStoreThrowsClosedForEveryOperation() throws {
        let store = try makeStore()
        store.close()
        XCTAssertEqual(storeError { _ = try store.medications() }, .closed)
        XCTAssertEqual(storeError { _ = try store.allDoses() }, .closed)
        XCTAssertEqual(storeError { _ = try store.doses(of: self.penID) }, .closed)
        XCTAssertEqual(storeError { try store.saveMedication(self.pen) }, .closed)
        XCTAssertEqual(storeError { try store.removeMedication(id: self.penID) }, .closed)
        XCTAssertEqual(storeError { try store.saveDose(self.dose("2.5", at: 1_789_961_400)) }, .closed)
        XCTAssertEqual(storeError { try store.removeDose(id: UUID()) }, .closed)
        XCTAssertEqual(storeError { try store.eraseAll() }, .closed)
    }

    func testAnUnreadableMedicationFailsTheWholeRead() throws {
        let store = try makeStore()
        try store.saveMedication(pen)
        try store.saveMedication(drops)
        try store.writeCorruptMedicationForTesting(id: dropsID, unitText: "mL")
        XCTAssertTrue(isCorrupt { _ = try store.medications() })

        let other = try makeStore()
        try other.saveMedication(pen)
        try other.writeCorruptMedicationForTesting(id: penID, name: "")
        XCTAssertTrue(isCorrupt { _ = try other.medications() })
    }

    func testAnUnreadableDoseFailsTheWholeRead() throws {
        for corrupt in [
            (amountText: "1.2.3", unitText: nil, zone: nil),
            (amountText: "0", unitText: nil, zone: nil),
            (amountText: nil, unitText: "units", zone: nil),
            (amountText: nil, unitText: nil, zone: "Not/AZone"),
        ] as [(amountText: String?, unitText: String?, zone: String?)] {
            let store = try makeStore()
            try store.saveMedication(pen)
            let kept = dose("2.5", at: 1_789_961_400)
            let damaged = dose("5", at: 1_790_566_200)
            try store.saveDose(kept)
            try store.saveDose(damaged)
            try store.writeCorruptDoseForTesting(
                id: damaged.id, amountText: corrupt.amountText, unitText: corrupt.unitText,
                timeZoneIdentifier: corrupt.zone)
            XCTAssertTrue(isCorrupt { _ = try store.doses(of: self.penID) }, "\(corrupt)")
            XCTAssertTrue(isCorrupt { _ = try store.allDoses() }, "\(corrupt)")
        }
    }

    // MARK: In-memory store

    func testAnInMemoryStoreThatFailsReadsFailsEveryRead() {
        let store = InMemoryMedicationStore(medications: [pen], failReads: true)
        for _ in 0..<3 {
            XCTAssertThrowsError(try store.medications())
            XCTAssertThrowsError(try store.allDoses())
            XCTAssertThrowsError(try store.doses(of: penID))
        }
    }

    func testAnInMemoryStoreThatRefusesWritesChangesNothing() throws {
        let taken = dose("2.5", at: 1_789_961_400)
        let store = InMemoryMedicationStore(medications: [pen], doses: [taken], refusesWrites: true)
        XCTAssertThrowsError(try store.saveMedication(drops))
        XCTAssertThrowsError(try store.removeMedication(id: penID))
        XCTAssertThrowsError(try store.saveDose(dose("5", at: 1_790_566_200)))
        XCTAssertThrowsError(try store.removeDose(id: taken.id))
        XCTAssertEqual(try store.medications(), [pen])
        XCTAssertEqual(try store.allDoses(), [taken])
    }
}
