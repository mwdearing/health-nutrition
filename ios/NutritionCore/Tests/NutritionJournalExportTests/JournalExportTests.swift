import Foundation
import NutritionDomain
@testable import NutritionJournal
import XCTest

/// A journal store held in memory, so the export tests do not depend on a file store and can hold values a
/// real store would refuse to create, such as a revision that points at a missing snapshot.
private final class StubJournalStore: JournalStore, JournalTombstoneSource, @unchecked Sendable {
    struct Unsupported: Error {}

    var failNextSaveForTesting = false
    var intakes: [Intake] = []
    var deleted: [Intake] = []
    var revisionsByIntake: [String: [IntakeRevision]] = [:]
    var products: [String: ProductDefinition] = [:]

    func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision { throw Unsupported() }

    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String, now: Date
    ) throws -> IntakeRevision { throw Unsupported() }

    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { intakes }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { revisionsByIntake[intakeID] ?? [] }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { products[snapshotID] }
    func activeIntakesFromBackground() async throws -> [Intake] { intakes }
    func close() {}
    func deletedIntakes() throws -> [Intake] { deleted }
}

private final class StubFavoritesStore: FavoritesStore, @unchecked Sendable {
    var items: [FavoriteTemplate] = []

    func add(_ favorite: FavoriteTemplate) throws { items.append(favorite) }
    func remove(id: String) throws { items.removeAll { $0.id == id } }
    func list() throws -> [FavoriteTemplate] { items }
    func contains(id: String) throws -> Bool { items.contains { $0.id == id } }
    func close() {}
}

final class JournalExportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_705_313_700)
    private let firstID = "1f0c9d2a-6b3e-4a7f-9c5d-0e2b6f8a1d33"
    private let secondID = "7d4a1c55-9e2b-4f60-8a3d-5c1b0f7e2a94"

    private func intake(
        _ id: String, at date: Date = Date(timeIntervalSince1970: 1_705_264_200), revision: Int = 1
    ) -> Intake {
        Intake(
            id: id, category: "food", occurredAt: date, timeZoneIdentifier: "Europe/Berlin", meal: "breakfast",
            currentRevision: revision)
    }

    private func component(_ id: String, _ amount: Decimal) -> IntakeComponent {
        IntakeComponent(componentID: id, name: id.capitalized, amount: amount, unit: .g)
    }

    private func revision(
        _ intakeID: String, number: Int, components: [IntakeComponent], snapshotID: String? = nil
    ) -> IntakeRevision {
        IntakeRevision(
            intakeID: intakeID, number: number, components: components, productSnapshotID: snapshotID,
            changeReason: number == 1 ? "created" : "bigger bowl",
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_705_264_200 + TimeInterval(number) * 600)))
    }

    private func filledStore() -> StubJournalStore {
        let store = StubJournalStore()
        store.intakes = [intake(firstID, revision: 2)]
        store.revisionsByIntake[firstID] = [
            revision(firstID, number: 1, components: [component("oats", Decimal(string: "37.5")!)],
                     snapshotID: "snap-1"),
            revision(firstID, number: 2, components: [component("oats", Decimal(string: "55.5")!)],
                     snapshotID: "snap-1"),
        ]
        store.deleted = [intake(secondID, at: Date(timeIntervalSince1970: 1_705_180_000))]
        store.products["snap-1"] = ProductDefinition(
            snapshotID: "snap-1", productID: "product-oats", name: "Sample rolled oats", brand: "Sample Brand",
            barcode: "0000000000017", labelBasis: "per100g", catalogOrigin: "sample-catalog", catalogVersion: "1")
        return store
    }

    private func favorites() -> StubFavoritesStore {
        let favorites = StubFavoritesStore()
        favorites.items = [FavoriteTemplate(
            id: "fav-tea-1", displayName: "Sample tea", category: "drink",
            components: [FavoriteComponent(componentID: "tea", name: "Tea", amountText: "250", unitSymbol: "mL")])]
        return favorites
    }

    private func makeExport(
        store: StubJournalStore, favorites: StubFavoritesStore? = nil
    ) throws -> JournalExport {
        try JournalExporter.makeExport(
            store: store, favorites: favorites, appVersion: "0.1.0", exportedAt: now)
    }

    private func contractFile(_ name: String, _ fileExtension: String) throws -> Data {
        // The committed contracts are copied into this target's resources as `Contracts/example.v1.json`
        // and `Contracts/v1.schema.json`, so the Swift shapes and the JSON Schema cannot drift apart.
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Contracts"),
            "missing contract resource \(name).\(fileExtension)")
        return try Data(contentsOf: url)
    }

    // MARK: Document

    func testExportRoundTripsThroughJSONWithoutLosingAnything() throws {
        let store = filledStore()
        let document = try makeExport(store: store, favorites: favorites())
        let decoded = try JournalExporter.decode(try JournalExporter.encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.appVersion, "0.1.0")
        XCTAssertEqual(decoded.exportedAt, now)
        XCTAssertEqual(decoded.intakes.first?.revisions.count, 2)
    }

    func testEncoderOutputIsDeterministicForTheSameData() throws {
        let store = filledStore()
        let first = try JournalExporter.encode(try makeExport(store: store))
        let second = try JournalExporter.encode(try makeExport(store: store))
        XCTAssertEqual(first, second)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\"app_version\":"))
    }

    func testExportKeepsEveryRevisionAndProvenanceOfEachIntake() throws {
        let document = try makeExport(store: filledStore())
        let exported = try XCTUnwrap(document.intakes.first)
        XCTAssertEqual(exported.id, firstID)
        XCTAssertEqual(exported.revisions.map(\.number), [1, 2])
        XCTAssertEqual(exported.revisions.map(\.changeReason), ["created", "bigger bowl"])
        XCTAssertEqual(exported.currentRevision, 2)
        XCTAssertEqual(exported.timeZoneIdentifier, "Europe/Berlin")
        let provenance = try XCTUnwrap(exported.revisions.last?.provenance)
        XCTAssertEqual(provenance.snapshotID, "snap-1")
        XCTAssertEqual(provenance.catalogOrigin, "sample-catalog")
    }

    func testExportListsTombstonesSeparatelyAndKeepsDeletedEntriesOutOfIntakes() throws {
        let document = try makeExport(store: filledStore())
        XCTAssertEqual(document.intakes.map(\.id), [firstID])
        XCTAssertEqual(document.tombstones.map(\.intakeID), [secondID])
        XCTAssertEqual(document.tombstones.first?.revision, 1)
    }

    func testDecimalAmountsAreWrittenAsExactStringsAndSurviveAsDecimals() throws {
        let document = try makeExport(store: filledStore())
        let data = try JournalExporter.encode(document)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"amount\":\"37.5\""), text)
        XCTAssertFalse(text.contains("\"amount\":37.5"), text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let intakes = try XCTUnwrap(object["intakes"] as? [[String: Any]])
        let revisions = try XCTUnwrap(intakes.first?["revisions"] as? [[String: Any]])
        let components = try XCTUnwrap(revisions.last?["components"] as? [[String: Any]])
        XCTAssertEqual(components.first?["amount"] as? String, "55.5")
        XCTAssertEqual(components.first?["value_state"] as? String, "known")
        XCTAssertEqual(components.first?["unit"] as? String, "g")
        let decoded = try JournalExporter.decode(data)
        XCTAssertEqual(
            Decimal(string: try XCTUnwrap(decoded.intakes.first?.revisions.last?.components.first?.amount)),
            Decimal(string: "55.5"))
    }

    func testUnknownAmountIsNullWithTheUnknownValueStateAndNotZero() throws {
        let store = StubJournalStore()
        store.intakes = [intake(firstID)]
        store.revisionsByIntake[firstID] = [
            revision(firstID, number: 1, components: [component("oats", Decimal.nan)]),
        ]
        let document = try makeExport(store: store)
        let exported = try XCTUnwrap(document.intakes.first?.revisions.first?.components.first)
        XCTAssertEqual(exported.valueState, .unknown)
        XCTAssertNil(exported.amount)
        XCTAssertFalse(try JournalExporter.json(document).contains("\"amount\":0"))
    }

    func testEmptyJournalExportsEmptyCollectionsAndStillValidHeader() throws {
        let document = try makeExport(store: StubJournalStore(), favorites: StubFavoritesStore())
        XCTAssertEqual(document.schemaVersion, JournalExport.currentSchemaVersion)
        XCTAssertTrue(document.intakes.isEmpty)
        XCTAssertTrue(document.tombstones.isEmpty)
        XCTAssertTrue(document.favorites.isEmpty)
        let decoded = try JournalExporter.decode(try JournalExporter.encode(document))
        XCTAssertEqual(decoded, document)
    }

    func testFavoritesAreExportedAsStoredTemplatesSortedByID() throws {
        let favoritesStore = self.favorites()
        let document = try makeExport(store: StubJournalStore(), favorites: favoritesStore)
        let exported = try XCTUnwrap(document.favorites.first)
        XCTAssertEqual(exported.id, "fav-tea-1")
        XCTAssertEqual(exported.displayName, "Sample tea")
        XCTAssertEqual(exported.components.first?.amount, "250")
        XCTAssertEqual(exported.components.first?.unit, "mL")
        XCTAssertNil(exported.productSnapshotID)
    }

    func testARevisionWithAMissingProductSnapshotFailsLoudly() throws {
        let store = filledStore()
        store.products = [:]
        XCTAssertThrowsError(try makeExport(store: store)) { error in
            XCTAssertEqual(error as? JournalExportError, .missingProductSnapshot("snap-1"))
        }
    }

    func testFileNameIsUTCAndIndependentOfTheDevice() {
        XCTAssertEqual(JournalExporter.fileName(exportedAt: now), "journal-export-2024-01-15-101500.json")
    }

    // MARK: The committed contract

    func testCommittedExampleDecodesAndRoundTrips() throws {
        let decoded = try JournalExporter.decode(try contractFile("example.v1", "json"))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.appVersion, "0.1.0")
        XCTAssertEqual(decoded.intakes.count, 1)
        XCTAssertEqual(decoded.intakes.first?.revisions.map(\.number), [1, 2])
        XCTAssertEqual(decoded.intakes.first?.revisions.last?.components.first?.amount, "55.5")
        XCTAssertEqual(
            decoded.intakes.first?.revisions.first?.components.last?.valueState, .unknown)
        XCTAssertNil(decoded.intakes.first?.revisions.first?.components.last?.amount)
        XCTAssertEqual(decoded.intakes.first?.revisions.last?.provenance?.snapshotID, "snap-oats-1")
        XCTAssertEqual(decoded.tombstones.first?.intakeID, "7d4a1c55-9e2b-4f60-8a3d-5c1b0f7e2a94")
        XCTAssertEqual(decoded.favorites.first?.displayName, "Sample tea")
        let reencoded = try JournalExporter.decode(try JournalExporter.encode(decoded))
        XCTAssertEqual(reencoded, decoded)
    }

    func testEncoderTopLevelKeysMatchTheSchemaProperties() throws {
        let schemaData = try contractFile("v1.schema", "json")
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let document = try makeExport(store: filledStore(), favorites: favorites())
        let encoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JournalExporter.encode(document)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), Set(properties.keys))
        for key in ["schema_version", "exported_at", "app_version", "intakes", "tombstones", "favorites"] {
            XCTAssertNotNil(encoded[key], key)
        }
        XCTAssertEqual(encoded["schema_version"] as? Int, 1)
    }
}