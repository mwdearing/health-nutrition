import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The strict shape pass: a version 2 document has to have exactly the keys the schema gives each object,
/// with the required-but-nullable ones present as an explicit `null` rather than left out. An ordinary
/// decoder ignores both kinds of difference, so a file that violates the contract would otherwise import,
/// and whatever it carried that this build does not understand would quietly disappear on the next export.
/// The version 1 documents this build still reads are held to their own schema in the same way, because
/// a field a version 1 build could not write is as unknown to a version 1 reader as any other.
final class JournalImportStrictShapeTests: XCTestCase {
    private let intakeID = "1f0c9d2a-6b3e-4a7f-9c5d-0e2b6f8a1d33"
    private let exportedAt = Date(timeIntervalSince1970: 1_705_310_100)
    /// The same instant as the text an export writes. Values put into a document that is going to be
    /// re-serialized have to be JSON text, never a Swift `Date`, which `JSONSerialization` refuses.
    private let exportedAtText = "2024-01-15T09:15:00Z"

    private func document(
        intakes: [JournalExportIntake] = [], tombstones: [JournalExportTombstone] = [],
        favorites: [JournalExportFavorite] = [], products: [JournalExportProvenance] = []
    ) -> JournalExport {
        JournalExport(
            exportedAt: exportedAt, appVersion: "0.1.0", intakes: intakes, tombstones: tombstones,
            favorites: favorites, products: products)
    }

    private func component(_ id: String = "oats", amount: String? = "40") -> JournalExportComponent {
        JournalExportComponent(
            componentID: id, name: "Sample rolled oats", amount: amount, unit: "g",
            valueState: amount == nil ? .unknown : .known)
    }

    private func provenance(_ snapshotID: String = "snap-oats-1") -> JournalExportProvenance {
        JournalExportProvenance(
            snapshotID: snapshotID, productID: "product-oats", name: "Sample rolled oats",
            brand: "Sample Brand", barcode: "0000000000017", labelBasis: "per100g",
            catalogOrigin: "sample-catalog", catalogVersion: "1")
    }

    private func revision(
        snapshotID: String? = nil, product: JournalExportProvenance? = nil
    ) -> JournalExportRevision {
        JournalExportRevision(
            number: 1, createdAt: exportedAt, changeReason: "created", productSnapshotID: snapshotID,
            provenance: product, components: [component()])
    }

    private func intake(
        revisions: [JournalExportRevision], current: Int = 1
    ) -> JournalExportIntake {
        JournalExportIntake(
            id: intakeID, category: "food", occurredAt: exportedAt, timeZoneIdentifier: "Europe/Berlin",
            meal: "breakfast", note: nil, currentRevision: current, revisions: revisions)
    }

    private func favorite(_ components: [JournalExportComponent]) -> JournalExportFavorite {
        JournalExportFavorite(
            id: "fav-oats-1", displayName: "Sample oats", category: "food", meal: nil,
            productSnapshotID: nil, components: components)
    }

    /// One valid document, encoded as plain JSON, so a test can add or take away a key.
    private func fields(_ document: JournalExport) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JournalExporter.encode(document)) as? [String: Any])
    }

    private func encoded(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields)
    }

    private func importInto(_ fields: [String: Any]) throws -> JournalImportSummary {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let favoritesStore = try SwiftDataFavoritesStore(
            url: directory.appendingPathComponent("favorites.store"))
        defer {
            store.close()
            favoritesStore.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return try JournalImporter.importExport(
            try encoded(fields), into: store, favorites: favoritesStore)
    }

    /// Asserts a document is refused, and says which kind of refusal it was: a shape that does not match
    /// the schema is a malformed file, not a corrupt one.
    private func assertRefusedAsMalformed(_ fields: [String: Any], line: UInt = #line) throws {
        do {
            _ = try importInto(fields)
            XCTFail("the document should have been refused", line: line)
        } catch let error as JournalImportError {
            guard case .malformed = error else {
                return XCTFail("expected a malformed file, got \(error)", line: line)
            }
        }
    }

    // MARK: The key sets themselves

    func testTheStrictKeySetsAreExactlyWhatTheCommittedSchemaStates() throws {
        // The keys are written out by hand so the importer can check a file without a JSON Schema
        // library, which means they could drift from the contract. This walks up to the committed schema
        // and holds every key set to it, at every level, both ways: nothing this importer requires may be
        // missing there, and nothing there may be unknown to this importer.
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: try schemaURL())) as? [String: Any])
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let expected: [(definition: String?, keys: Set<String>)] = [
            (nil, JournalImportV1Keys.root),
            ("intake", JournalImportV1Keys.intake),
            ("revision", JournalImportV1Keys.revision),
            ("provenance", JournalImportV1Keys.provenance),
            ("component", JournalImportV1Keys.component),
            ("tombstone", JournalImportV1Keys.tombstone),
            ("favorite", JournalImportV1Keys.favorite),
        ]
        for entry in expected {
            let shape: [String: Any]
            if let definition = entry.definition {
                shape = try XCTUnwrap(definitions[definition] as? [String: Any], definition)
            } else {
                shape = schema
            }
            let properties = try XCTUnwrap(shape["properties"] as? [String: Any], "\(entry.keys)")
            let required = try XCTUnwrap(shape["required"] as? [String], "\(entry.keys)")
            XCTAssertEqual(Set(properties.keys), entry.keys, "the schema and the importer disagree on the keys")
            XCTAssertEqual(Set(required), entry.keys, "every property the schema lists has to be required")
        }
    }

    /// Version 2 is version 1 with the product's kind, so the sets are held to the committed version 2
    /// schema in the same way, and the one that differs is the provenance.
    func testTheVersion2KeySetsAreExactlyWhatTheCommittedSchemaStates() throws {
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: try schemaURL(version: 2))) as? [String: Any])
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let expected: [(definition: String?, keys: Set<String>)] = [
            (nil, JournalImportV2Keys.root),
            ("intake", JournalImportV2Keys.intake),
            ("revision", JournalImportV2Keys.revision),
            ("provenance", JournalImportV2Keys.provenance),
            ("component", JournalImportV2Keys.component),
            ("tombstone", JournalImportV2Keys.tombstone),
            ("favorite", JournalImportV2Keys.favorite),
        ]
        for entry in expected {
            var shape = schema
            if let definition = entry.definition {
                shape = try XCTUnwrap(definitions[definition] as? [String: Any], definition)
            }
            let properties = try XCTUnwrap(shape["properties"] as? [String: Any], "\(entry.keys)")
            let required = try XCTUnwrap(shape["required"] as? [String], "\(entry.keys)")
            XCTAssertEqual(Set(properties.keys), entry.keys)
            XCTAssertEqual(Set(required), entry.keys)
        }
        XCTAssertEqual(
            JournalImportV2Keys.provenance.subtracting(JournalImportV1Keys.provenance), ["kind"],
            "version 2 adds the kind and changes nothing else")
    }

    /// The kind is required from version 2 on: a document that declares version 2 and leaves it out is
    /// not a version 2 document, whatever a decoder would make of it.
    func testAMissingKindInAVersion2ProvenanceIsRefused() throws {
        var fields = try fields(
            document(
                intakes: [intake(revisions: [revision(snapshotID: "snap-oats-1", product: provenance())])],
                products: [provenance()]))
        var products = try XCTUnwrap(fields["products"] as? [[String: Any]])
        products[0].removeValue(forKey: "kind")
        fields["products"] = products
        try assertRefusedAsMalformed(fields)
    }

    /// And in a version 1 document it is an unknown key, because that build had no such field: a reader
    /// that ignored it would drop the kind on the next export without saying so.
    func testAKindInAVersion1ProvenanceIsRefused() throws {
        var fields = try fields(
            document(
                intakes: [intake(revisions: [revision(snapshotID: "snap-oats-1", product: provenance())])],
                products: [provenance()]))
        fields["schema_version"] = 1
        var products = try XCTUnwrap(fields["products"] as? [[String: Any]])
        products[0].removeValue(forKey: "kind")
        fields["products"] = products
        try assertRefusedAsMalformed(fields)
    }

    func testAValidDocumentStillImports() throws {
        let summary = try importInto(
            try fields(document(
                intakes: [intake(revisions: [revision(snapshotID: "snap-oats-1", product: provenance())])],
                favorites: [favorite([component()])],
                products: [provenance()])))
        XCTAssertEqual(summary.intakes, 1)
        XCTAssertEqual(summary.favorites, 1)
    }

    // MARK: Unknown keys

    func testAnUnknownKeyAtTheTopLevelIsRefused() throws {
        var fields = try fields(document())
        fields["something_this_build_does_not_know"] = "a value"
        try assertRefusedAsMalformed(fields)
    }

    func testAnUnknownKeyInsideAnEntryIsRefused() throws {
        var fields = try fields(document(intakes: [intake(revisions: [revision()])]))
        var intakes = try XCTUnwrap(fields["intakes"] as? [[String: Any]])
        intakes[0]["barcode"] = "0000000000017"
        fields["intakes"] = intakes
        try assertRefusedAsMalformed(fields)
    }

    func testAnUnknownKeyInsideARevisionIsRefused() throws {
        var fields = try fields(document(intakes: [intake(revisions: [revision()])]))
        var intakes = try XCTUnwrap(fields["intakes"] as? [[String: Any]])
        var first = intakes[0]
        var revisions = try XCTUnwrap(first["revisions"] as? [[String: Any]])
        revisions[0]["eaten_at"] = exportedAtText
        first["revisions"] = revisions
        intakes[0] = first
        fields["intakes"] = intakes
        try assertRefusedAsMalformed(fields)
    }

    func testAnUnknownKeyInsideAComponentIsRefused() throws {
        var fields = try fields(document(intakes: [intake(revisions: [revision()])]))
        var intakes = try XCTUnwrap(fields["intakes"] as? [[String: Any]])
        var first = intakes[0]
        var revisions = try XCTUnwrap(first["revisions"] as? [[String: Any]])
        var components = try XCTUnwrap(revisions[0]["components"] as? [[String: Any]])
        components[0]["grams"] = "40"
        revisions[0]["components"] = components
        first["revisions"] = revisions
        intakes[0] = first
        fields["intakes"] = intakes
        try assertRefusedAsMalformed(fields)
    }

    func testAnUnknownKeyInsideProvenanceIsRefused() throws {
        var fields = try fields(
            document(
                intakes: [intake(revisions: [revision(snapshotID: "snap-oats-1", product: provenance())])],
                products: [provenance()]))
        var products = try XCTUnwrap(fields["products"] as? [[String: Any]])
        products[0]["nutrients"] = ["energy": "380"]
        fields["products"] = products
        try assertRefusedAsMalformed(fields)
    }

    func testAnUnknownKeyInsideAFavoriteIsRefused() throws {
        var fields = try fields(document(favorites: [favorite([component()])]))
        var favoriteList = try XCTUnwrap(fields["favorites"] as? [[String: Any]])
        favoriteList[0]["is_pinned"] = true
        fields["favorites"] = favoriteList
        try assertRefusedAsMalformed(fields)
    }

    func testAnUnknownKeyInsideATombstoneIsRefused() throws {
        var fields = try fields(
            document(tombstones: [
                JournalExportTombstone(
                    intakeID: intakeID, revision: 1, occurredAt: exportedAt,
                    timeZoneIdentifier: "Europe/Berlin")
            ]))
        var tombstones = try XCTUnwrap(fields["tombstones"] as? [[String: Any]])
        tombstones[0]["deleted_at"] = exportedAtText
        fields["tombstones"] = tombstones
        try assertRefusedAsMalformed(fields)
    }

    // MARK: Missing keys

    func testAMissingRequiredKeyAtTheTopLevelIsRefused() throws {
        var fields = try fields(document())
        fields["app_version"] = nil
        try assertRefusedAsMalformed(fields)
    }

    func testAMissingRequiredNullableKeyIsRefusedRatherThanReadAsAbsent() throws {
        // `note` is required but nullable: absent and explicitly null mean different things to the schema,
        // and a decoder cannot tell them apart.
        var fields = try fields(document(intakes: [intake(revisions: [revision()])]))
        var intakes = try XCTUnwrap(fields["intakes"] as? [[String: Any]])
        intakes[0].removeValue(forKey: "note")
        fields["intakes"] = intakes
        try assertRefusedAsMalformed(fields)
    }

    func testAMissingRequiredNullableKeyInsideProvenanceIsRefused() throws {
        var fields = try fields(
            document(
                intakes: [intake(revisions: [revision(snapshotID: "snap-oats-1", product: provenance())])],
                products: [provenance()]))
        var products = try XCTUnwrap(fields["products"] as? [[String: Any]])
        products[0].removeValue(forKey: "barcode")
        fields["products"] = products
        try assertRefusedAsMalformed(fields)
    }

    func testAMissingRequiredKeyInsideAComponentIsRefused() throws {
        var fields = try fields(document(favorites: [favorite([component()])]))
        var favoriteList = try XCTUnwrap(fields["favorites"] as? [[String: Any]])
        var components = try XCTUnwrap(favoriteList[0]["components"] as? [[String: Any]])
        components[0].removeValue(forKey: "value_state")
        favoriteList[0]["components"] = components
        fields["favorites"] = favoriteList
        try assertRefusedAsMalformed(fields)
    }

    func testAMissingKeyInsideAnEntryThatHasNoRevisionsYetIsRefused() throws {
        var fields = try fields(document(intakes: [intake(revisions: [revision()])]))
        var intakes = try XCTUnwrap(fields["intakes"] as? [[String: Any]])
        intakes[0].removeValue(forKey: "current_revision")
        fields["intakes"] = intakes
        try assertRefusedAsMalformed(fields)
    }

    // MARK: Wrong shapes

    func testAnObjectThatShouldBeAListIsRefused() throws {
        var fields = try fields(document())
        fields["intakes"] = ["not an object"]
        try assertRefusedAsMalformed(fields)
    }

    func testAListThatShouldBeAnObjectIsRefused() throws {
        var fields = try fields(document(intakes: [intake(revisions: [revision()])]))
        var intakes = try XCTUnwrap(fields["intakes"] as? [[String: Any]])
        var first = intakes[0]
        first["revisions"] = "one, two"
        intakes[0] = first
        fields["intakes"] = intakes
        try assertRefusedAsMalformed(fields)
    }

    func testAMissingTopLevelKeyIsNotReadAsAnEmptyList() throws {
        var fields = try fields(document())
        fields["favorites"] = nil
        try assertRefusedAsMalformed(fields)
    }

    /// Walks up from this source file to the repository root, then into the committed contracts.
    /// The committed schema for a version, found by walking up to the repository root. Reading the
    /// committed file rather than a copy is deliberate: the copies under the test targets exist for the
    /// export tests, and this is where a change to the contract would be caught.
    private func schemaURL(version: Int = 1) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent(
                "contracts/journal-export/v\(version).schema.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw XCTSkip("the committed schema is not next to this source tree")
    }
}
