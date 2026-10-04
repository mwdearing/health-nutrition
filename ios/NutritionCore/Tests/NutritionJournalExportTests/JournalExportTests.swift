import Foundation
import NutritionDomain
@testable import NutritionJournal
import XCTest

/// A journal store held in memory, so the export tests do not depend on a file store and can hold values a
/// real store would refuse to create, such as a revision that points at a missing snapshot.
class StubJournalStore: JournalStore, JournalTombstoneSource, @unchecked Sendable {
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

/// A store that answers the whole read in one call, the way `SwiftDataJournalStore` does, and records which
/// per-list methods were touched so a test can prove the exporter asked for one snapshot and not two lists.
private final class SnapshotStubStore: StubJournalStore, JournalSnapshotSource {
    var snapshotCallCount = 0
    var perListCallCount = 0
    var snapshot = JournalSnapshot(activeIntakes: [], deletedIntakes: [])

    func readJournalSnapshot() throws -> JournalSnapshot {
        snapshotCallCount += 1
        return snapshot
    }

    override func activeIntakes() throws -> [Intake] {
        perListCallCount += 1
        return try super.activeIntakes()
    }

    override func revisions(of intakeID: String) throws -> [IntakeRevision] {
        perListCallCount += 1
        return try super.revisions(of: intakeID)
    }
}

/// Counts the snapshot lookups the exporter makes, so a test can prove an immutable product is fetched once
/// rather than once per revision.
private final class CountingSnapshotStore: StubJournalStore, JournalSnapshotSource {
    var productQueryCount = 0
    var snapshot = JournalSnapshot(activeIntakes: [], deletedIntakes: [])

    func readJournalSnapshot() throws -> JournalSnapshot { snapshot }

    override func product(snapshotID: String) throws -> ProductDefinition? {
        productQueryCount += 1
        return try super.product(snapshotID: snapshotID)
    }
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

    func testEveryNullableContractFieldIsWrittenAsAnExplicitJSONNull() throws {
        // Nothing in this document has a meal, a note, a brand or a barcode, and the second intake has no
        // product at all, so a synthesized encoder would leave all of those keys out of a schema that requires
        // them. The first intake also carries an unknown amount, which must be written as null and not omitted.
        let store = StubJournalStore()
        store.intakes = [
            Intake(
                id: firstID, category: "water", occurredAt: now, timeZoneIdentifier: "Europe/Berlin",
                currentRevision: 1),
            intake(secondID, revision: 1),
        ]
        store.revisionsByIntake[firstID] = [
            IntakeRevision(
                intakeID: firstID, number: 1,
                components: [component("water", Decimal.nan), component("oats", Decimal(string: "40")!)],
                productSnapshotID: nil, changeReason: "created", createdAt: now),
        ]
        store.revisionsByIntake[secondID] = [
            revision(secondID, number: 1, components: [component("oats", Decimal(string: "40")!)],
                     snapshotID: "snap-1"),
        ]
        store.products["snap-1"] = ProductDefinition(
            snapshotID: "snap-1", productID: "product-oats", name: "Sample rolled oats",
            labelBasis: "per100g", catalogOrigin: "sample-catalog", catalogVersion: "1")
        let favoritesStore = StubFavoritesStore()
        favoritesStore.items = [FavoriteTemplate(
            id: "fav-plain-1", displayName: "Sample water", category: "drink",
            components: [FavoriteComponent(componentID: "water", name: "Water", amountText: "250", unitSymbol: "mL")])]
        let data = try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: store, favorites: favoritesStore, appVersion: "0.1.0", exportedAt: now))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"meal\":null"), text)
        XCTAssertTrue(text.contains("\"note\":null"), text)
        XCTAssertTrue(text.contains("\"provenance\":null"), text)
        XCTAssertTrue(text.contains("\"product_snapshot_id\":null"), text)
        XCTAssertTrue(text.contains("\"amount\":null"), text)
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provenance = try XCTUnwrap((document["products"] as? [[String: Any]])?.first)
        XCTAssertTrue(provenance["brand"] is NSNull, "a product without a brand writes brand as null")
        XCTAssertTrue(provenance["barcode"] is NSNull, "a product without a barcode writes barcode as null")
        let favorite = try XCTUnwrap((document["favorites"] as? [[String: Any]])?.first)
        XCTAssertTrue(favorite["meal"] is NSNull, "a favorite without a meal writes meal as null")
        XCTAssertTrue(favorite["product_snapshot_id"] is NSNull)
    }

    func testAnExportFullOfNullsHasEveryKeyTheSchemaRequires() throws {
        // The committed example has a note, a product and a brand; a real export often has none of them.
        // This walks the encoded document against the schema's own `required` lists so the writer, not just
        // the round-trip test, is held to the contract.
        let store = StubJournalStore()
        store.intakes = [
            Intake(
                id: firstID, category: "water", occurredAt: now, timeZoneIdentifier: "Europe/Berlin",
                currentRevision: 1),
        ]
        store.revisionsByIntake[firstID] = [
            IntakeRevision(
                intakeID: firstID, number: 1,
                components: [component("water", Decimal.nan), component("oats", Decimal(string: "40")!)],
                productSnapshotID: nil, changeReason: "created", createdAt: now),
        ]
        store.deleted = [intake(secondID, at: now, revision: 2)]
        let favoritesStore = StubFavoritesStore()
        favoritesStore.items = [FavoriteTemplate(
            id: "fav-plain-1", displayName: "Sample water", category: "drink",
            components: [FavoriteComponent(componentID: "water", name: "Water", amountText: "250", unitSymbol: "mL")])]
        let data = try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: store, favorites: favoritesStore, appVersion: "0.1.0", exportedAt: now))
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try contractFile("v1.schema", "json")) as? [String: Any])
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])

        try assertRequiredKeys(encoded, against: schema, definitionName: nil, path: "$")
        for (key, definition) in [
            ("intakes", "intake"), ("tombstones", "tombstone"), ("favorites", "favorite"), ("products", "provenance"),
        ] {
            for item in try XCTUnwrap(encoded[key] as? [[String: Any]], key) {
                try assertRequiredKeys(item, against: schema, definitionName: definition, path: "$.\(key)")
            }
        }
        let intakes = try XCTUnwrap(encoded["intakes"] as? [[String: Any]])
        for intake in intakes {
            for revision in try XCTUnwrap(intake["revisions"] as? [[String: Any]]) {
                try assertRequiredKeys(revision, against: schema, definitionName: "revision", path: "$.revisions")
                let provenance = try XCTUnwrap(revision["provenance"])
                if let object = provenance as? [String: Any] {
                    try assertRequiredKeys(
                        object, against: schema, definitionName: "provenance", path: "$.provenance")
                } else {
                    XCTAssertTrue(provenance is NSNull, "a missing provenance must be null, not absent")
                }
                for component in try XCTUnwrap(revision["components"] as? [[String: Any]]) {
                    try assertRequiredKeys(
                        component, against: schema, definitionName: "component", path: "$.components")
                }
            }
        }
        XCTAssertFalse(definitions.isEmpty, "the schema must define the object shapes")
    }

    /// Checks one encoded object against the shape the schema states for it: every required key is present,
    /// even when its value is `null`, and no key the schema does not define turns up.
    private func assertRequiredKeys(
        _ object: [String: Any], against schema: [String: Any], definitionName: String?, path: String
    ) throws {
        let shape: [String: Any]
        if let definitionName {
            let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any], "the schema must define $defs")
            shape = try XCTUnwrap(
                definitions[definitionName] as? [String: Any], "the schema does not define \(definitionName)")
        } else {
            shape = schema
        }
        let required = try XCTUnwrap(shape["required"] as? [String], "\(path) has no required list in the schema")
        for key in required {
            XCTAssertNotNil(object[key], "\(path) is missing the required key \(key)")
        }
        let properties = try XCTUnwrap(shape["properties"] as? [String: Any], "\(path) has no properties")
        for key in object.keys where properties[key] == nil {
            XCTFail("\(path) has \(key), which the schema does not define")
        }
    }

    func testOneDateFormatterIsBuiltPerRunNotPerDate() throws {
        // Building a DateFormatter is the expensive part of formatting a date, and an export has one date per
        // intake, revision and header. This test counts the formatters a run builds.
        let original = JournalExporter.dateFormatter
        addTeardownBlock { JournalExporter.dateFormatter = original }
        var builds = 0
        JournalExporter.dateFormatter = {
            builds += 1
            return original()
        }
        let document = try makeExport(store: filledStore(), favorites: favorites())
        XCTAssertTrue(document.intakes.first?.revisions.first?.createdAt.timeIntervalSince1970 ?? 0 > 0)
        builds = 0
        let data = try JournalExporter.encode(document)
        XCTAssertEqual(builds, 1, "one formatter for the whole encode run")
        builds = 0
        _ = try JournalExporter.decode(data)
        XCTAssertEqual(builds, 1, "one formatter for the whole decode run")
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

    func testSubMillisecondTimestampsSurviveSoOrderingIsNeverLost() throws {
        let store = StubJournalStore()
        let base = Date(timeIntervalSince1970: 1_705_264_200)
        // Two entries 0.2 milliseconds apart: a three-digit fraction rounds both onto the same instant, six
        // digits keep them apart. The gap is still far below a millisecond, so this fails a rounded writer.
        store.intakes = [
            intake(firstID, at: base.addingTimeInterval(0.123_4), revision: 1),
            intake(secondID, at: base.addingTimeInterval(0.123_6), revision: 1),
        ]
        store.revisionsByIntake[firstID] = [
            IntakeRevision(
                intakeID: firstID, number: 1, components: [component("oats", Decimal(string: "40")!)],
                productSnapshotID: nil, changeReason: "created",
                createdAt: base.addingTimeInterval(0.000_001)),
        ]
        store.revisionsByIntake[secondID] = [
            IntakeRevision(
                intakeID: secondID, number: 1, components: [component("tea", Decimal(string: "250")!)],
                productSnapshotID: nil, changeReason: "created",
                createdAt: base.addingTimeInterval(0.999_999)),
        ]
        let document = try JournalExporter.makeExport(
            store: store, favorites: nil, appVersion: "0.1.0",
            exportedAt: base.addingTimeInterval(0.555_555))
        let text = try JournalExporter.json(document)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.123400Z"), text)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.123600Z"), text)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.000001Z"), text)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.999999Z"), text)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.555555Z"), text)
        let decoded = try JournalExporter.decode(try JournalExporter.encode(document))
        // A tolerance of one microsecond catches millisecond rounding (which moves a timestamp by up to half a
        // millisecond) without demanding more of a `Date` than its own resolution.
        let tolerance = 0.000_001
        XCTAssertEqual(decoded.exportedAt.timeIntervalSince1970, base.addingTimeInterval(0.555_555).timeIntervalSince1970, accuracy: tolerance)
        let occurred = decoded.intakes.sorted { $0.id < $1.id }.map(\.occurredAt)
        XCTAssertEqual(occurred.count, 2)
        XCTAssertNotEqual(occurred[0], occurred[1], "two entries 0.2 ms apart must not collapse onto one instant")
        XCTAssertEqual(occurred[0].timeIntervalSince1970, base.addingTimeInterval(0.123_4).timeIntervalSince1970, accuracy: tolerance)
        XCTAssertEqual(occurred[1].timeIntervalSince1970, base.addingTimeInterval(0.123_6).timeIntervalSince1970, accuracy: tolerance)
        let created = decoded.intakes.first?.revisions.first?.createdAt
        XCTAssertEqual(
            try XCTUnwrap(created).timeIntervalSince1970, base.addingTimeInterval(0.000_001).timeIntervalSince1970,
            accuracy: tolerance)
    }

    func testMillisecondAndWholeSecondDatesWrittenByEarlierBuildsStillDecode() throws {
        // Three-digit and no-digit date text must keep importing; the committed example uses whole seconds.
        let milliseconds = try JournalExporter.decode(
            Data(#"{"schema_version":1,"exported_at":"2024-01-15T09:15:00.250Z","app_version":"0.1.0","intakes":[],"tombstones":[],"favorites":[],"products":[]}"#.utf8))
        XCTAssertEqual(milliseconds.exportedAt.timeIntervalSince1970, 1_705_310_100.25)
        let wholeSeconds = try JournalExporter.decode(
            Data(#"{"schema_version":1,"exported_at":"2024-01-15T09:15:00Z","app_version":"0.1.0","intakes":[],"tombstones":[],"favorites":[],"products":[]}"#.utf8))
        XCTAssertEqual(wholeSeconds.exportedAt.timeIntervalSince1970, 1_705_310_100)
    }

    func testAMalformedFavoriteAmountFailsTheExportRatherThanWritingAnUnusableBackup() throws {
        // The favorites store accepts decimal-looking text such as "1.2.3", which the schema's decimal
        // pattern does not allow, so the export must refuse it rather than call it a known amount.
        let favoritesStore = StubFavoritesStore()
        favoritesStore.items = [FavoriteTemplate(
            id: "fav-broken-1", displayName: "Sample broken", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "1.2.3", unitSymbol: "g")])]
        XCTAssertThrowsError(
            try JournalExporter.makeExport(
                store: StubJournalStore(), favorites: favoritesStore, appVersion: "0.1.0", exportedAt: now)
        ) { error in
            XCTAssertEqual(error as? JournalExportError, .malformedFavoriteAmount("fav-broken-1", "1.2.3"))
        }
    }

    func testWellFormedFavoriteAmountsAreStillExported() throws {
        let favoritesStore = StubFavoritesStore()
        favoritesStore.items = [
            FavoriteTemplate(
                id: "fav-a-1", displayName: "Sample whole", category: "food",
                components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "250", unitSymbol: "g")]),
            FavoriteTemplate(
                id: "fav-b-1", displayName: "Sample decimal", category: "food",
                components: [FavoriteComponent(
                    componentID: "oats", name: "Oats", amountText: "0.5", unitSymbol: "g")]),
        ]
        let document = try JournalExporter.makeExport(
            store: StubJournalStore(), favorites: favoritesStore, appVersion: "0.1.0", exportedAt: now)
        // Sorted by id, not by the order the store happens to list them in, so two exports of the same
        // favorites are the same document.
        XCTAssertEqual(document.favorites.map(\.id), ["fav-a-1", "fav-b-1"])
        XCTAssertEqual(document.favorites.map(\.components.first?.amount), ["250", "0.5"])
        let reversed = StubFavoritesStore()
        reversed.items = favoritesStore.items.reversed()
        let other = try JournalExporter.makeExport(
            store: StubJournalStore(), favorites: reversed, appVersion: "0.1.0", exportedAt: now)
        XCTAssertEqual(try JournalExporter.encode(other), try JournalExporter.encode(document))
    }

    func testOneProductSnapshotIsResolvedOnceEvenWhenManyRevisionsUseIt() throws {
        let store = CountingSnapshotStore()
        let snapshot = ProductDefinition(
            snapshotID: "snap-1", productID: "product-oats", name: "Sample rolled oats",
            labelBasis: "per100g", catalogOrigin: "sample-catalog", catalogVersion: "1")
        store.snapshot = JournalSnapshot(
            activeIntakes: [JournalExportIntakeSnapshot(
                intake: intake(firstID, revision: 3),
                revisions: (1...3).map { number in
                    IntakeRevision(
                        intakeID: firstID, number: number,
                        components: [component("oats", Decimal(string: "40")!)],
                        productSnapshotID: "snap-1", changeReason: "created",
                        createdAt: Date(timeIntervalSince1970: TimeInterval(1_705_264_200 + number * 60)))
                })],
            deletedIntakes: [])
        store.products["snap-1"] = snapshot
        let document = try JournalExporter.makeExport(
            store: store, favorites: nil, appVersion: "0.1.0", exportedAt: now)
        XCTAssertEqual(store.productQueryCount, 1, "an immutable snapshot must not be fetched once per revision")
        XCTAssertEqual(document.products.map(\.snapshotID), ["snap-1"])
        XCTAssertEqual(document.intakes.first?.revisions.count, 3)
    }

    func testFractionalSecondsSurviveEncodingSoTwoEntriesInOneSecondStayDistinct() throws {
        let store = StubJournalStore()
        let base = Date(timeIntervalSince1970: 1_705_264_200)
        store.intakes = [
            intake(firstID, at: base.addingTimeInterval(0.25), revision: 1),
            intake(secondID, at: base.addingTimeInterval(0.75), revision: 1),
        ]
        store.revisionsByIntake[firstID] = [
            IntakeRevision(
                intakeID: firstID, number: 1, components: [component("oats", Decimal(string: "40")!)],
                productSnapshotID: nil, changeReason: "created",
                createdAt: base.addingTimeInterval(0.125)),
        ]
        store.revisionsByIntake[secondID] = [
            IntakeRevision(
                intakeID: secondID, number: 1, components: [component("tea", Decimal(string: "250")!)],
                productSnapshotID: nil, changeReason: "created",
                createdAt: base.addingTimeInterval(0.875)),
        ]
        let document = try JournalExporter.makeExport(
            store: store, favorites: nil, appVersion: "0.1.0",
            exportedAt: base.addingTimeInterval(0.5))
        let text = try JournalExporter.json(document)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.250000Z"), text)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.125000Z"), text)
        XCTAssertTrue(text.contains("2024-01-14T20:30:00.500000Z"), text)
        let decoded = try JournalExporter.decode(try JournalExporter.encode(document))
        XCTAssertEqual(decoded.appVersion, document.appVersion)
        XCTAssertEqual(decoded.intakes.map(\.id), document.intakes.map(\.id))
        let occurred = decoded.intakes.sorted { $0.id < $1.id }.map(\.occurredAt)
        XCTAssertEqual(occurred.count, 2)
        XCTAssertNotEqual(occurred[0], occurred[1], "two entries in one second must stay in order")
        XCTAssertEqual(occurred[0].timeIntervalSince1970, base.addingTimeInterval(0.25).timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(occurred[1].timeIntervalSince1970, base.addingTimeInterval(0.75).timeIntervalSince1970, accuracy: 0.000_001)
    }

    func testWholeSecondDatesFromTheCommittedExampleStillDecode() throws {
        // The example was written before fractional seconds were kept; a reader must not reject it.
        let decoded = try JournalExporter.decode(try contractFile("example.v1", "json"))
        XCTAssertEqual(decoded.exportedAt, Date(timeIntervalSince1970: 1_705_310_100))
    }

    func testDecodingADocumentFromANewerSchemaVersionIsRefused() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try JournalExporter.encode(try makeExport(store: filledStore()))) as? [String: Any])
        object["schema_version"] = 2
        object["field_this_build_does_not_know"] = "something"
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JournalExporter.decode(data)) { error in
            XCTAssertEqual(error as? JournalExportError, .unsupportedSchemaVersion(2))
        }
    }

    func testProductSnapshotsAreListedSoAFavoriteCanOutliveItsIntakes() throws {
        // The only intake that used the snapshot is deleted, so no revision carries its provenance any more.
        let store = filledStore()
        store.intakes = []
        store.deleted = [
            intake(firstID, at: Date(timeIntervalSince1970: 1_705_264_200), revision: 1),
            intake(secondID, at: Date(timeIntervalSince1970: 1_705_180_000)),
        ]
        store.revisionsByIntake = [:]
        let favoritesStore = StubFavoritesStore()
        favoritesStore.items = [FavoriteTemplate(
            id: "fav-oats-1", displayName: "Sample oats", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "55.5", unitSymbol: "g")],
            productSnapshotID: "snap-1")]
        let document = try JournalExporter.makeExport(
            store: store, favorites: favoritesStore, appVersion: "0.1.0", exportedAt: now)
        XCTAssertTrue(document.intakes.isEmpty)
        XCTAssertEqual(document.products.map(\.snapshotID), ["snap-1"])
        let product = try XCTUnwrap(document.products.first)
        XCTAssertEqual(product.productID, "product-oats")
        XCTAssertEqual(product.catalogOrigin, "sample-catalog")
        // It survives the JSON round trip, so a restore has everything the repeat path asks for.
        let decoded = try JournalExporter.decode(try JournalExporter.encode(document))
        XCTAssertEqual(decoded.products.map(\.snapshotID), ["snap-1"])
        XCTAssertEqual(decoded.favorites.first?.productSnapshotID, "snap-1")
    }

    func testAFavoriteWithAMissingSnapshotFailsLoudlyRatherThanExportingADanglingID() throws {
        let store = filledStore()
        store.intakes = []
        store.revisionsByIntake = [:]
        store.products = [:]
        let favoritesStore = StubFavoritesStore()
        favoritesStore.items = [FavoriteTemplate(
            id: "fav-oats-1", displayName: "Sample oats", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "55.5", unitSymbol: "g")],
            productSnapshotID: "snap-1")]
        XCTAssertThrowsError(
            try JournalExporter.makeExport(
                store: store, favorites: favoritesStore, appVersion: "0.1.0", exportedAt: now)
        ) { error in
            XCTAssertEqual(error as? JournalExportError, .missingProductSnapshot("snap-1"))
        }
    }

    func testExportIsBuiltFromOneSnapshotReadRatherThanSeparateLists() throws {
        let store = SnapshotStubStore()
        store.snapshot = JournalSnapshot(
            activeIntakes: [JournalExportIntakeSnapshot(
                intake: intake(firstID, revision: 2),
                revisions: [
                    IntakeRevision(
                        intakeID: firstID, number: 1, components: [component("oats", Decimal(string: "40")!)],
                        productSnapshotID: nil, changeReason: "created",
                        createdAt: Date(timeIntervalSince1970: 1_705_264_200)),
                    IntakeRevision(
                        intakeID: firstID, number: 2, components: [component("oats", Decimal(string: "55.5")!)],
                        productSnapshotID: nil, changeReason: "bigger bowl",
                        createdAt: Date(timeIntervalSince1970: 1_705_264_800)),
                ])],
            deletedIntakes: [intake(secondID, at: Date(timeIntervalSince1970: 1_705_180_000))])
        let document = try JournalExporter.makeExport(
            store: store, favorites: nil, appVersion: "0.1.0", exportedAt: now)
        XCTAssertEqual(store.snapshotCallCount, 1)
        XCTAssertEqual(store.perListCallCount, 0, "a separate list read could miss an entry deleted in between")
        XCTAssertEqual(document.intakes.first?.revisions.map(\.number), [1, 2])
        XCTAssertEqual(document.tombstones.map(\.intakeID), [secondID])
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
        XCTAssertEqual(decoded.products.map(\.snapshotID), ["snap-oats-1"])
        XCTAssertEqual(decoded.products.first?.productID, "product-oats")
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
        for key in ["schema_version", "exported_at", "app_version", "intakes", "tombstones", "favorites", "products"] {
            XCTAssertNotNil(encoded[key], key)
        }
        XCTAssertEqual(encoded["schema_version"] as? Int, 1)
        let products = try XCTUnwrap(properties["products"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(products["items"] as? [String: Any])["$ref"] as? String, "#/$defs/provenance")
        // `required` is a sibling of `properties` at the top level of the schema, not one of its entries.
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("products"), "products is required")
        XCTAssertEqual(Set(required), Set(properties.keys), "every schema property is required")
    }

    func testSchemaTiesAnAmountToItsValueState() throws {
        // The schema, not only the writer, has to reject "amount: null but known" and "amount: \"5\" but unknown".
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try contractFile("v1.schema", "json")) as? [String: Any])
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let component = try XCTUnwrap(definitions["component"] as? [String: Any])
        XCTAssertNotNil(component["oneOf"], "amount and value_state must be constrained together")
        let branches = try XCTUnwrap(component["oneOf"] as? [[String: Any]])
        let cases: [String: String] = [
            "known": "string", "unknown": "null",
        ]
        XCTAssertEqual(branches.count, cases.count)
        for branch in branches {
            let properties = try XCTUnwrap(branch["properties"] as? [String: Any])
            let amount = try XCTUnwrap(properties["amount"] as? [String: Any])
            let valueState = try XCTUnwrap(properties["value_state"] as? [String: Any])
            let state = try XCTUnwrap(valueState["const"] as? String)
            XCTAssertEqual(amount["type"] as? String, cases[state], state)
        }
        XCTAssertNotNil(try XCTUnwrap(branches.first?["properties"] as? [String: Any])["amount"])
    }

    /// The contract files in `contracts/journal-export` are the canonical ones; the copies bundled as test
    /// resources must be byte-for-byte identical, or the Swift tests would be checking a stale contract.
    func testBundledContractCopiesMatchTheCanonicalFiles() throws {
        for name in ["example.v1.json", "v1.schema.json"] {
            let bundled = try contractFileResource(name)
            let canonical = try XCTUnwrap(
                canonicalContractURL(name), "the canonical contract \(name) is missing from contracts/journal-export")
            let canonicalData = try Data(contentsOf: canonical)
            XCTAssertEqual(
                bundled, canonicalData,
                "\(name) has drifted from contracts/journal-export; copy the canonical file over "
                    + "ios/NutritionCore/Tests/NutritionJournalExportTests/Contracts/\(name)")
        }
    }

    private func contractFileResource(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Contracts"),
            "missing bundled contract \(name)")
        return try Data(contentsOf: url)
    }

    /// Walks up from this source file to the repository root, then into `contracts/journal-export`.
    private func canonicalContractURL(_ name: String) -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("contracts/journal-export/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }
}