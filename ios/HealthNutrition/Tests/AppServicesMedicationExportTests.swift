import Foundation
import NutritionDomain
import NutritionJournal
@testable import NutritionUI
import XCTest

@testable import HealthNutrition

/// The Settings export carries the medication log the app stores. The app passes its medication store to the
/// Connections and privacy screen, so an export from the app writes the medications and doses it holds. If the app
/// stopped passing the store, this export would carry no medications and the test would fail.
@MainActor
final class AppServicesMedicationExportTests: XCTestCase {
    func testTheSettingsExportCarriesTheMedicationLogTheAppStores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let services = try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler())
        let vial = Medication(
            id: UUID(uuidString: "0A000000-0000-4000-8000-000000000001")!, name: "Example vial", unit: .mg,
            scheduleDays: 7)
        let dose = MedicationDose(
            id: UUID(uuidString: "0D000000-0000-4000-8000-000000000001")!, medicationID: vial.id,
            takenAt: Date(timeIntervalSince1970: 1_776_086_400), timeZoneIdentifier: "UTC",
            amount: Decimal(string: "2.5")!, unit: .mg, site: "Left side")
        try services.medicationStore.saveMedication(vial)
        try services.medicationStore.saveDose(dose)

        XCTAssertTrue(services.connections.export(now: Date(timeIntervalSince1970: 1_777_000_000)))
        let url = try XCTUnwrap(services.connections.exportFileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let document = try JournalExporter.decode(Data(contentsOf: url))

        XCTAssertEqual(document.medications, [JournalExportMedication(medication: vial)])
        XCTAssertEqual(document.medicationDoses, [JournalExportMedicationDose(dose: dose)])
    }
}
