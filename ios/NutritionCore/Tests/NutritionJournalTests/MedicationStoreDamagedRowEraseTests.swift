import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// A row that fails the app's own checks fails every read of the log, but the erase deletes rows without reading them
/// back through those checks, so the clear removes the log from a file SQLite finds healthy.
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
}
