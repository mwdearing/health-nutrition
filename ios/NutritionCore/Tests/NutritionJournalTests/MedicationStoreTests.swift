import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// Where the medication log is kept: the medications a person named and the doses they typed, in their
/// own store file, `medications.store`.
///
/// The rules are the same for the SwiftData store and the in-memory one, so each rule test runs against
/// both. A store never changes what was typed: a dose reads back with the amount, unit, time, zone, site
/// and note it was saved with, and a row that cannot be read fails the read rather than vanishing from it.
/// Erasing replaces the store file, as every other store's erase does.
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
        zone: String = "America/Chicago", site: String? = nil, note: String? = nil, id: UUID = UUID()
    ) -> MedicationDose {
        MedicationDose(
            id: id, medicationID: medicationID ?? penID, takenAt: Date(timeIntervalSince1970: seconds),
            timeZoneIdentifier: zone, amount: amount(text), unit: unit, site: site, note: note)
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

    func testEveryUnitAndTheSiteRoundTrip() throws {
        for (kind, store) in try freshStores() {
            let vial = Medication(id: penID, name: "Example vial", unit: .mL, scheduleDays: 7)
            let unitPen = Medication(id: dropsID, name: "Example unit pen", unit: .units)
            try store.saveMedication(vial)
            try store.saveMedication(unitPen)
            XCTAssertEqual(try store.medications(), [unitPen, vial], kind)
            let drawn = dose("0.25", unit: .mL, at: 1_789_961_400, site: "Left thigh")
            let dialed = dose("12", of: dropsID, unit: .units, at: 1_790_200_000)
            try store.saveDose(drawn)
            try store.saveDose(dialed)
            XCTAssertEqual(try store.doses(of: penID), [drawn], kind)
            XCTAssertEqual(try store.doses(of: penID).first?.site, "Left thigh", kind)
            XCTAssertEqual(try store.doses(of: dropsID), [dialed], kind)
            XCTAssertNil(try store.doses(of: dropsID).first?.site, kind)
        }
    }

    func testADoseWithAnInvalidSiteWritesNothing() throws {
        for (kind, store) in try freshStores() {
            try store.saveMedication(pen)
            XCTAssertThrowsError(try store.saveDose(dose("2.5", at: 1_789_961_400, site: " ")), kind) { error in
                XCTAssertEqual(error as? MedicationError, .siteEmpty, kind)
            }
            XCTAssertEqual(try store.allDoses(), [], kind)
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
        let typed = dose(
            "0.125", at: 1_789_961_400, zone: "Asia/Tokyo", site: "Abdomen, left", note: "Second pen of the box")
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
        XCTAssertEqual(try reopened.doses(of: penID).first?.site, "Abdomen, left")
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
        try store.writeCorruptMedicationForTesting(id: dropsID, unitText: "ml")
        XCTAssertTrue(isCorrupt { _ = try store.medications() })

        let other = try makeStore()
        try other.saveMedication(pen)
        try other.writeCorruptMedicationForTesting(id: penID, name: "")
        XCTAssertTrue(isCorrupt { _ = try other.medications() })
    }

    func testAnUnreadableDoseFailsTheWholeRead() throws {
        for corrupt in [
            (amountText: "1.2.3", unitText: nil, zone: nil, site: nil),
            (amountText: "0", unitText: nil, zone: nil, site: nil),
            (amountText: nil, unitText: "IU", zone: nil, site: nil),
            (amountText: nil, unitText: nil, zone: "Not/AZone", site: nil),
            (amountText: nil, unitText: nil, zone: nil, site: " "),
            (amountText: nil, unitText: nil, zone: nil, site: String(repeating: "s", count: 41)),
        ] as [(amountText: String?, unitText: String?, zone: String?, site: String?)] {
            let store = try makeStore()
            try store.saveMedication(pen)
            let kept = dose("2.5", at: 1_789_961_400)
            let damaged = dose("5", at: 1_790_566_200)
            try store.saveDose(kept)
            try store.saveDose(damaged)
            try store.writeCorruptDoseForTesting(
                id: damaged.id, amountText: corrupt.amountText, unitText: corrupt.unitText,
                timeZoneIdentifier: corrupt.zone, site: corrupt.site)
            XCTAssertTrue(isCorrupt { _ = try store.doses(of: self.penID) }, "\(corrupt)")
            XCTAssertTrue(isCorrupt { _ = try store.allDoses() }, "\(corrupt)")
        }
    }

    // MARK: Erase replaces the store file

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testAnEraseReplacesTheStoreFileAndTheStoreStaysUsable() throws {
        let url = try makeDirectory().appendingPathComponent("medications.store")
        let store = try SwiftDataMedicationStore(url: url)
        try store.saveMedication(pen)
        try store.saveDose(dose("2.5", at: 1_789_961_400, site: "Left thigh"))
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
        // A plain read handle keeps the old file's number allocated, so the replacement cannot reuse it.
        let pinned = try FileHandle(forReadingFrom: url)
        defer { try? pinned.close() }

        try store.eraseAll()

        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
        XCTAssertNotEqual(before, after, "the erase deleted rows but left the store file in place")
        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
        try store.saveMedication(drops)
        store.close()
        let reopened = try SwiftDataMedicationStore(url: url)
        XCTAssertEqual(try reopened.medications(), [drops])
        reopened.close()
    }

    func testAFailedFileRemovalIsReportedAndStopsTheErase() throws {
        let url = try makeDirectory().appendingPathComponent("medications.store")
        let calls = MedicationRemovedFiles()
        let store = try SwiftDataMedicationStore(
            url: url,
            fileOperations: StoreFileOperations(
                checkpoint: { _ in },
                remove: { file in
                    calls.names.append(file.lastPathComponent)
                    throw CocoaError(.fileWriteNoPermission)
                },
                openContainer: SwiftDataMedicationStore.makeContainer))
        try store.saveMedication(pen)
        try store.saveDose(dose("2.5", at: 1_789_961_400))

        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(calls.names.count, 1, "the erase stops at the first failed removal")
        // The rows were deleted before the files, and the store reopened on the file the erase left.
        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
        store.close()
    }

    func testAFailedCheckpointRemovesNothing() throws {
        let url = try makeDirectory().appendingPathComponent("medications.store")
        let calls = MedicationRemovedFiles()
        let store = try SwiftDataMedicationStore(
            url: url,
            fileOperations: StoreFileOperations(
                checkpoint: { _ in throw StoreFileError.checkpointFailed },
                remove: { file in
                    calls.names.append(file.lastPathComponent)
                    try FileManager.default.removeItem(at: file)
                },
                openContainer: SwiftDataMedicationStore.makeContainer))
        try store.saveMedication(pen)

        XCTAssertThrowsError(try store.eraseAll()) { XCTAssertEqual($0 as? StoreFileError, .checkpointFailed) }
        XCTAssertTrue(calls.names.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.close()
    }

    func testAFailedReopenIsReportedAndRetriedByTheNextCall() throws {
        let url = try makeDirectory().appendingPathComponent("medications.store")
        let reopen = MedicationReopenSwitch()
        let store = try SwiftDataMedicationStore(
            url: url,
            fileOperations: StoreFileOperations(
                checkpoint: { _ in },
                remove: { try FileManager.default.removeItem(at: $0) },
                openContainer: { url in
                    if reopen.fails { throw CocoaError(.fileWriteNoPermission) }
                    return try SwiftDataMedicationStore.makeContainer(url: url)
                }))
        try store.saveMedication(pen)

        reopen.fails = true
        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertThrowsError(try store.medications()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        reopen.fails = false
        XCTAssertEqual(try store.medications(), [])
        store.close()
        XCTAssertEqual(storeError { _ = try store.medications() }, .closed)
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

/// The file names a test's removal step was asked to delete, in order.
private final class MedicationRemovedFiles: @unchecked Sendable {
    var names: [String] = []
}

/// Lets a test make the store's reopen fail, then succeed, on later calls.
private final class MedicationReopenSwitch: @unchecked Sendable {
    var fails = false
}
