import Foundation
import NutritionDomain
import NutritionJournal
@testable import NutritionUI
import XCTest

@testable import HealthNutrition

/// A medications.store that cannot be opened never stops the app from starting, so a person who never turned the
/// Medication log on is never blocked by it. The log says it cannot be read and offers to clear itself; clearing it,
/// or Erase all data, replaces the damaged file with an empty store. Nothing removes the file without one of those.
@MainActor
final class AppServicesMedicationStartupTests: XCTestCase {
    /// A fresh directory per test whose medications.store holds bytes that are not a store.
    private func makeDamagedDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("not a store".utf8).write(to: directory.appendingPathComponent("medications.store"))
        return directory
    }

    private func makeServices(_ directory: URL) throws -> AppServices {
        try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler())
    }

    func testADamagedMedicationFileDoesNotBlockLaunch() throws {
        let directory = try makeDamagedDirectory()
        let services = try makeServices(directory)

        XCTAssertTrue(try services.journalStore.activeIntakes().isEmpty)
        XCTAssertTrue(try services.goalStore.goals().isEmpty)
        services.medicationLog.load()
        XCTAssertEqual(services.medicationLog.errorMessage, "Could not read the medication log.")
        XCTAssertTrue(services.medicationLog.canClear)
    }

    func testTheDamagedFileStaysUntilThePersonClearsIt() throws {
        let directory = try makeDamagedDirectory()
        let services = try makeServices(directory)
        services.medicationLog.load()
        services.medicationLog.load()

        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("medications.store")), Data("not a store".utf8))
    }

    func testClearingTheLogReplacesADamagedFile() throws {
        let directory = try makeDamagedDirectory()
        let services = try makeServices(directory)
        services.medicationLog.load()

        services.medicationLog.clearLog()

        XCTAssertNil(services.medicationLog.errorMessage)
        XCTAssertFalse(services.medicationLog.canClear)
        XCTAssertEqual(services.medicationLog.rows, [])
        XCTAssertNil(services.medicationLog.addMedication(name: "Example vial", unit: .mL, scheduleDaysText: ""))
        XCTAssertEqual(services.medicationLog.rows.map(\.name), ["Example vial"])
        XCTAssertEqual(try services.medicationStore.medications().map(\.name), ["Example vial"])
    }

    func testEraseAllDataReplacesADamagedFile() async throws {
        let directory = try makeDamagedDirectory()
        let services = try makeServices(directory)
        services.medicationLog.load()

        let erased = await services.connections.eraseAllData()

        XCTAssertTrue(erased)
        XCTAssertEqual(try services.medicationStore.medications(), [])
        XCTAssertNil(services.medicationLog.errorMessage)
        XCTAssertFalse(services.medicationLog.canClear)
    }

    func testAHealthyFileShowsNoClear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let services = try makeServices(directory)
        services.medicationLog.load()

        XCTAssertNil(services.medicationLog.errorMessage)
        XCTAssertFalse(services.medicationLog.canClear)
    }
}
