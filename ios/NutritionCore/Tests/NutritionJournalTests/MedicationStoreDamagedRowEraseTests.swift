import Foundation
import NutritionDomain
import SQLite3
import SwiftData
import XCTest
@testable import NutritionJournal

/// A row that fails the app's own checks fails every read of the log, but the erase deletes rows without reading them
/// back through those checks, so the clear removes the log from a file SQLite finds healthy. A row written outside the
/// app with a required field missing does not stop the erase either: the file replacement removes it.
final class MedicationStoreDamagedRowEraseTests: XCTestCase {
    private func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("medications.store")
    }

    func testAnEraseRemovesAMedicationRowThatFailsTheChecks() throws {
        let url = try makeURL()
        let store = SwiftDataMedicationStore(retryingOpenAt: url)
        addTeardownBlock { store.close() }
        let medication = Medication(name: "Example vial", unit: .mL)
        try store.saveMedication(medication)
        try store.writeCorruptMedicationForTesting(id: medication.id, unitText: "not a unit")
        XCTAssertThrowsError(try store.medications())
        XCTAssertFalse(SwiftDataMedicationStore.storeFileIsDamaged(at: url), "the file itself is healthy")

        try store.eraseAll()

        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
    }

    func testAnEraseRemovesADoseRowThatFailsTheChecks() throws {
        let url = try makeURL()
        let store = SwiftDataMedicationStore(retryingOpenAt: url)
        addTeardownBlock { store.close() }
        let medication = Medication(name: "Example weekly injection", unit: .mg, scheduleDays: 7)
        try store.saveMedication(medication)
        let dose = MedicationDose(
            medicationID: medication.id, takenAt: Date(timeIntervalSince1970: 1_776_159_000),
            timeZoneIdentifier: "UTC", amount: 2.5, unit: .mg)
        try store.saveDose(dose)
        try store.writeCorruptDoseForTesting(id: dose.id, amountText: "not an amount")
        XCTAssertThrowsError(try store.allDoses())

        try store.eraseAll()

        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
    }

    func testAnEraseRemovesARowWithARequiredFieldMissing() throws {
        let url = try makeURL()
        // The first store lives in its own autorelease pool, so anything Core Data left in the pool for the file's
        // connection is released here, before the raw write below, and not when the test method returns.
        try autoreleasepool {
            let first = SwiftDataMedicationStore(retryingOpenAt: url)
            try first.saveMedication(Medication(name: "Example vial", unit: .mL))
            first.close()
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        // `close()` only drops the store's container; the file's last connection can be released a moment later, and a
        // write in that moment is refused as busy (SQLITE_BUSY, 5, seen in CI). This connection waits up to 10 s for
        // the lock (the store's own file check waits 2 s), so the write below is judged on what it does, not on timing.
        XCTAssertEqual(sqlite3_busy_timeout(database, 10_000), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "UPDATE ZMEDICATIONRECORD SET ZNAME = NULL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_changes(database), 1, "the row written outside the app has no name")
        sqlite3_close(database)
        XCTAssertFalse(SwiftDataMedicationStore.storeFileIsDamaged(at: url), "the file itself is healthy")

        let store = SwiftDataMedicationStore(retryingOpenAt: url)
        addTeardownBlock { store.close() }
        try store.eraseAll()

        XCTAssertEqual(try store.medications(), [], "the person sees an empty log, and the clear does not keep failing")
        XCTAssertEqual(try store.allDoses(), [])
    }
}
