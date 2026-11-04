import Foundation
import NutritionDomain
@testable import NutritionJournal
import XCTest

/// The medication log in a version 9 export: every medication, archived ones included, and every dose with its
/// amount, its zone, its site and its note. The export is the person's own copy of what they logged, so it leaves
/// nothing out, and a store that cannot be read fails the export rather than writing a file without the log.
final class JournalExportMedicationsTests: XCTestCase {
    private let vial = Medication(
        id: UUID(uuidString: "0A000000-0000-4000-8000-000000000001")!, name: "Example vial", unit: .mg,
        scheduleDays: 7)
    private let pen = Medication(
        id: UUID(uuidString: "0A000000-0000-4000-8000-000000000002")!, name: "Example pen", unit: .units,
        isArchived: true)

    private func dose(_ number: Int, _ medication: Medication, amount: Decimal, site: String? = nil, note: String? = nil)
        -> MedicationDose
    {
        MedicationDose(
            id: UUID(uuidString: "0D000000-0000-4000-8000-00000000000\(number)")!, medicationID: medication.id,
            takenAt: Date(timeIntervalSince1970: TimeInterval(1_776_000_000 + number * 86_400)),
            timeZoneIdentifier: number == 1 ? "America/Chicago" : "UTC", amount: amount, unit: medication.unit,
            site: site, note: note)
    }

    private func export(_ medications: MedicationStore?) throws -> JournalExport {
        try JournalExporter.makeExport(
            store: StubJournalStore(), goals: InMemoryGoalStore(), medications: medications, appVersion: "test",
            exportedAt: Date(timeIntervalSince1970: 1_777_000_000))
    }

    private func json(_ export: JournalExport) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: try JournalExporter.encode(export)) as? [String: Any])
    }

    private func store() -> InMemoryMedicationStore {
        InMemoryMedicationStore(
            medications: [vial, pen],
            doses: [
                dose(1, vial, amount: Decimal(string: "2.5")!, site: "Left side", note: "After lunch"),
                dose(2, vial, amount: 5), dose(3, pen, amount: 1000),
            ])
    }

    func testThisBuildWritesVersion9AndReadsEveryEarlierVersion() {
        XCTAssertEqual(JournalExport.currentSchemaVersion, 9)
        XCTAssertEqual(JournalExport.readableSchemaVersions, Set(1...9))
    }

    func testTheExportCarriesEveryMedicationAndDoseSortedByID() throws {
        let document = try export(store())

        XCTAssertEqual(document.schemaVersion, 9)
        XCTAssertEqual(document.medications, [
            JournalExportMedication(
                id: vial.id.uuidString, name: "Example vial", unit: "mg", scheduleDays: 7, isArchived: false),
            JournalExportMedication(
                id: pen.id.uuidString, name: "Example pen", unit: "units", scheduleDays: nil, isArchived: true),
        ])
        XCTAssertEqual(document.medicationDoses.map(\.id), [1, 2, 3].map { dose($0, vial, amount: 1).id.uuidString })
        let first = try XCTUnwrap(document.medicationDoses.first)
        XCTAssertEqual(first, JournalExportMedicationDose(
            id: dose(1, vial, amount: 1).id.uuidString, medicationID: vial.id.uuidString,
            takenAt: Date(timeIntervalSince1970: 1_776_086_400), timeZone: "America/Chicago", amount: "2.5", unit: "mg",
            site: "Left side", note: "After lunch"))
        XCTAssertEqual(document.medicationDoses[2].amount, "1000", "exact decimal text, no grouping")
        XCTAssertEqual(document.medicationDoses[2].unit, "units")
    }

    func testTheJSONStatesBothListsWithEveryKeyAndNullsForWhatIsNotSet() throws {
        let root = try json(try export(store()))

        XCTAssertEqual(root["schema_version"] as? Int, 9)
        let medications = try XCTUnwrap(root["medications"] as? [[String: Any]])
        let doses = try XCTUnwrap(root["medication_doses"] as? [[String: Any]])
        XCTAssertEqual(medications.count, 2)
        XCTAssertEqual(doses.count, 3)
        for medication in medications {
            XCTAssertEqual(Set(medication.keys), ["id", "name", "unit", "schedule_days", "is_archived"])
        }
        for dose in doses {
            XCTAssertEqual(
                Set(dose.keys), ["id", "medication_id", "taken_at", "time_zone", "amount", "unit", "site", "note"])
        }
        let archived = try XCTUnwrap(medications.first { $0["name"] as? String == "Example pen" })
        XCTAssertTrue(archived["schedule_days"] is NSNull, "no schedule is written as null, never left out")
        XCTAssertEqual(archived["is_archived"] as? Bool, true)
        let plain = try XCTUnwrap(doses.first { $0["amount"] as? String == "5" })
        XCTAssertTrue(plain["site"] is NSNull)
        XCTAssertTrue(plain["note"] is NSNull)
        XCTAssertEqual(plain["taken_at"] as? String, "2026-04-14T13:20:00.000000Z")
        let full = try XCTUnwrap(doses.first { $0["amount"] as? String == "2.5" })
        XCTAssertEqual(full["site"] as? String, "Left side", "the site is the person's data, so the export keeps it")
        XCTAssertEqual(full["note"] as? String, "After lunch")
        XCTAssertEqual(full["time_zone"] as? String, "America/Chicago")
    }

    func testAVersion9ExportRoundTripsThroughJSON() throws {
        let document = try export(store())
        XCTAssertEqual(try JournalExporter.decode(try JournalExporter.encode(document)), document)
    }

    func testAnExportWithoutAMedicationStoreStatesEmptyLists() throws {
        let root = try json(try export(nil))
        XCTAssertEqual((root["medications"] as? [Any])?.count, 0)
        XCTAssertEqual((root["medication_doses"] as? [Any])?.count, 0)
    }

    func testAMedicationStoreThatCannotBeReadFailsTheExport() {
        XCTAssertThrowsError(try export(InMemoryMedicationStore(failReads: true)))
    }

    func testAVersion8DocumentKeepsItsShapeWithoutTheMedicationLists() throws {
        let document = JournalExport(
            schemaVersion: 8, exportedAt: Date(timeIntervalSince1970: 1_777_000_000), appVersion: "test",
            intakes: [], tombstones: [], favorites: [], goals: [],
            medications: [JournalExportMedication(medication: vial)])
        let root = try json(document)
        XCTAssertNil(root["medications"])
        XCTAssertNil(root["medication_doses"])
        XCTAssertNotNil(root["goals"])
    }

    func testAVersion8DocumentReadsWithNoMedications() throws {
        let data = try JournalExporter.encode(JournalExport(
            schemaVersion: 8, exportedAt: Date(timeIntervalSince1970: 1_777_000_000), appVersion: "test",
            intakes: [], tombstones: [], favorites: [], goals: []))
        let document = try JournalExporter.decode(data)
        XCTAssertEqual(document.medications, [])
        XCTAssertEqual(document.medicationDoses, [])
    }

    // MARK: - Contract

    private func contractFile(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Contracts"),
            "missing bundled contract \(name)")
        return try Data(contentsOf: url)
    }

    /// Walks up from this source file to the repository root, then into `contracts/journal-export`.
    private func canonicalContractURL(_ name: String) -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("contracts/journal-export/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    func testTheVersion9ContractFilesAreBundledUnchanged() throws {
        for name in ["v9.schema.json", "example.v9.json"] {
            let canonical = try XCTUnwrap(canonicalContractURL(name), "contracts/journal-export/\(name) is missing")
            XCTAssertEqual(try contractFile(name), try Data(contentsOf: canonical), "\(name) has drifted")
        }
    }

    func testTheVersion9SchemaRequiresBothListsAndEveryKey() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: try contractFile("v9.schema.json")) as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("medications"))
        XCTAssertTrue(required.contains("medication_doses"))
        XCTAssertTrue(required.contains("goals"))
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let version = try XCTUnwrap(properties["schema_version"] as? [String: Any])
        XCTAssertEqual(version["const"] as? Int, 9)
        for (key, fields) in [
            ("medications", ["id", "name", "unit", "schedule_days", "is_archived"]),
            ("medication_doses", ["id", "medication_id", "taken_at", "time_zone", "amount", "unit", "site", "note"]),
        ] {
            let list = try XCTUnwrap(properties[key] as? [String: Any], key)
            XCTAssertEqual(list["type"] as? String, "array")
            let items = try XCTUnwrap(list["items"] as? [String: Any], key)
            XCTAssertEqual(items["additionalProperties"] as? Bool, false, key)
            XCTAssertEqual(Set(try XCTUnwrap(items["required"] as? [String], key)), Set(fields), key)
        }
    }

    func testTheVersion9ExampleReadsAndEveryDoseNamesAMedicationInIt() throws {
        let document = try JournalExporter.decode(try contractFile("example.v9.json"))
        XCTAssertEqual(document.schemaVersion, 9)
        XCTAssertFalse(document.medications.isEmpty)
        XCTAssertFalse(document.medicationDoses.isEmpty)
        let ids = Set(document.medications.map(\.id))
        for dose in document.medicationDoses {
            XCTAssertTrue(ids.contains(dose.medicationID), dose.id)
        }
        let names = document.medications.map(\.name).joined(separator: " ")
        XCTAssertTrue(names.hasPrefix("Example"), "the example uses synthetic names only")
    }
}
