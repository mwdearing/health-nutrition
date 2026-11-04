import Foundation
import NutritionDomain
@testable import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Connections and privacy screen carries the medication log: its export writes the medications and doses, its
/// import restores them add-only into the medication store it was given, and the success line counts them.
@MainActor
final class ConnectionsPrivacyMedicationsTests: XCTestCase {
    private let vial = Medication(
        id: UUID(uuidString: "0A000000-0000-4000-8000-000000000001")!, name: "Example vial", unit: .mg,
        scheduleDays: 7)

    private var vialDose: MedicationDose {
        MedicationDose(
            id: UUID(uuidString: "0D000000-0000-4000-8000-000000000001")!, medicationID: vial.id,
            takenAt: Date(timeIntervalSince1970: 1_776_086_400), timeZoneIdentifier: "UTC",
            amount: Decimal(string: "2.5")!, unit: .mg, site: "Left side")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func stores() throws -> (SwiftDataJournalStore, SwiftDataMedicationStore) {
        let folder = try directory()
        let journal = try SwiftDataJournalStore(url: folder.appendingPathComponent("journal.store"))
        let medications = try SwiftDataMedicationStore(url: folder.appendingPathComponent("medications.store"))
        addTeardownBlock {
            journal.close()
            medications.close()
        }
        return (journal, medications)
    }

    private func importAndSettle(_ model: ConnectionsPrivacyViewModel, data: Data) async {
        model.importJournal(data: data)
        let deadline = Date(timeIntervalSinceNow: 10)
        while model.importState == .idle, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotEqual(model.importState, .idle, "the import never published an outcome")
    }

    func testThePickerRestoresAMedicationAndItsDoseFromAVersion9File() async throws {
        let (journal, medications) = try stores()
        let data = try JournalExporter.encode(JournalExport(
            exportedAt: Date(timeIntervalSince1970: 1_777_000_000), appVersion: "test", intakes: [], tombstones: [],
            favorites: [], goals: [], medications: [JournalExportMedication(medication: vial)],
            medicationDoses: [JournalExportMedicationDose(dose: vialDose)]))
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: journal, medications: medications)

        await importAndSettle(model, data: data)

        XCTAssertEqual(model.importState, .imported)
        XCTAssertEqual(try medications.medications(), [vial])
        XCTAssertEqual(try medications.allDoses(), [vialDose])
    }

    func testTheExportWritesTheMedicationLog() throws {
        let (journal, medications) = try stores()
        try medications.saveMedication(vial)
        try medications.saveDose(vialDose)
        final class Captured: @unchecked Sendable { var data: Data? }
        let captured = Captured()
        let model = ConnectionsPrivacyViewModel(
            goals: InMemoryGoalStore(), store: journal, medications: medications,
            writer: { data, _, _ in captured.data = data })

        XCTAssertTrue(model.export(now: Date(timeIntervalSince1970: 1_777_000_000)))

        let document = try JournalExporter.decode(try XCTUnwrap(captured.data))
        XCTAssertEqual(document.medications, [JournalExportMedication(medication: vial)])
        XCTAssertEqual(document.medicationDoses, [JournalExportMedicationDose(dose: vialDose)])
    }

    func testAMedicationStoreThatCannotBeReadFailsTheExport() throws {
        let (journal, _) = try stores()
        let model = ConnectionsPrivacyViewModel(
            goals: InMemoryGoalStore(), store: journal, medications: InMemoryMedicationStore(failReads: true),
            writer: { _, _, _ in })

        XCTAssertFalse(model.export(now: Date(timeIntervalSince1970: 1_777_000_000)))
    }

    func testTheSuccessLineCountsMedicationsAndDoses() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importSummaryText(JournalImportSummary(
                intakes: 1, revisions: 1, tombstones: 0, favorites: 0, products: 0, medications: 1,
                medicationDoses: 3), locale: locale),
            "Imported 1 entry, 1 medication, 3 doses.")
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importSummaryText(JournalImportSummary(
                intakes: 0, revisions: 0, tombstones: 0, favorites: 0, products: 0, goals: 2, medications: 2,
                medicationDoses: 1), locale: locale),
            "Imported 0 entries, 2 goals, 2 medications, 1 dose.")
        XCTAssertEqual(
            ConnectionsPrivacyViewModel.importSummaryText(JournalImportSummary(
                intakes: 0, revisions: 0, tombstones: 0, favorites: 0, products: 0, medicationDoses: 1_200),
                locale: locale),
            "Imported 0 entries, 1,200 doses.")
    }
}
