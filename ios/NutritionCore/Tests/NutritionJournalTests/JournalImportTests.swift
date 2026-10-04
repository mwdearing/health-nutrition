import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Fixtures for the import tests: real on-disk stores in unique temporary directories, and a filled
/// journal to export. Shared by every import test file, so it is written once here rather than copied
/// into each. It holds no tests of its own.
class JournalImportTestCase: XCTestCase {
    let oatsID = "1f0c9d2a-6b3e-4a7f-9c5d-0e2b6f8a1d33"
    let waterID = "7d4a1c55-9e2b-4f60-8a3d-5c1b0f7e2a94"
    let goneID = "2b9e4c07-51d8-4a63-8f2e-6c3a9d05b7e1"
    let otherID = "5e2a7c18-4b93-4d2e-9f61-8c5d3a7e0b42"
    /// A whole second, so the exported text carries no fraction and the round trip is exact.
    let exportedAt = Date(timeIntervalSince1970: 1_705_310_100)
    let base = Date(timeIntervalSince1970: 1_705_264_200)
    let appVersion = "0.1.0"

    // MARK: Fixtures

    func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func store(_ directory: URL) throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func favorites(_ directory: URL) throws -> SwiftDataFavoritesStore {
        try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
    }

    func oats(_ grams: String) -> IntakeComponent {
        IntakeComponent(
            componentID: "oats", name: "Sample rolled oats", amount: Decimal(string: grams)!, unit: .g)
    }

    func water(_ millilitres: String) -> IntakeComponent {
        IntakeComponent(
            componentID: "water", name: "Sample water", amount: Decimal(string: millilitres)!, unit: .mL)
    }

    /// The values the sample product states. They live with the snapshot, not in the document: an export
    /// records which product a revision used and where it came from, not what that product states, so a
    /// restore has to keep whatever values this store already holds rather than write empty ones over them.
    let sampleNutrients: [String: NutrientValue] = [
        "energy": .known(Decimal(string: "380")!, .kcal),
        "fibre": .unknown,
    ]

    func product() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snap-oats-1", productID: "product-oats", name: "Sample rolled oats",
            brand: "Sample Brand", barcode: "0000000000017", labelBasis: "per100g",
            catalogOrigin: "sample-catalog", catalogVersion: "1", nutrients: sampleNutrients)
    }

    /// A journal with two live entries, one of them edited once, and one entry already deleted.
    func filledStore(_ directory: URL) throws -> SwiftDataJournalStore {
        let store = try self.store(directory)
        try store.create(
            Intake(
                id: oatsID, category: "food", occurredAt: base, timeZoneIdentifier: "Europe/Berlin",
                meal: "breakfast"),
            components: [oats("37.5")], product: product(), now: base)
        try store.edit(
            intakeID: oatsID, components: [oats("55.5")], product: product(), changeReason: "bigger bowl",
            now: base.addingTimeInterval(600))
        try store.create(
            Intake(
                id: waterID, category: "drink", occurredAt: base.addingTimeInterval(3600),
                timeZoneIdentifier: "Europe/Berlin"),
            components: [water("250")], product: nil, now: base.addingTimeInterval(3600))
        try store.create(
            Intake(
                id: goneID, category: "food", occurredAt: base.addingTimeInterval(7200),
                timeZoneIdentifier: "Europe/Berlin"),
            components: [oats("20")], product: product(), now: base.addingTimeInterval(7200))
        try store.delete(intakeID: goneID, now: base.addingTimeInterval(7800))
        return store
    }

    func filledFavorites(_ directory: URL) throws -> SwiftDataFavoritesStore {
        let favorites = try self.favorites(directory)
        try favorites.add(
            FavoriteTemplate(
                id: "fav-tea-1", displayName: "Sample tea", category: "drink",
                components: [
                    FavoriteComponent(
                        componentID: "tea", name: "Sample tea", amountText: "250", unitSymbol: "mL")
                ]))
        try favorites.add(
            FavoriteTemplate(
                id: "fav-oats-1", displayName: "Sample oats", category: "food",
                components: [
                    FavoriteComponent(
                        componentID: "oats", name: "Sample oats", amountText: "0.5", unitSymbol: "g")
                ],
                productSnapshotID: "snap-oats-1", meal: "breakfast"))
        return favorites
    }

    /// The bytes a filled journal exports. A source directory is made per call unless one is given, so
    /// every test gets its own store file.
    func exportData(from source: URL? = nil, favorites included: Bool = true) throws -> Data {
        let directory = try source ?? self.directory()
        let journal = try filledStore(directory)
        let favoritesStore: SwiftDataFavoritesStore?
        if included {
            favoritesStore = try filledFavorites(directory)
        } else {
            favoritesStore = nil
        }
        return try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: journal, favorites: favoritesStore, appVersion: appVersion, exportedAt: exportedAt))
    }

    /// A document read back as plain JSON, so a test can change one field without rebuilding a journal.
    func object(of data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// One restored entry with the given number of revisions, for the tests that hand a plan straight to
    /// the store instead of going through a document.
    func entry(_ id: String, revisions revisionCount: Int) -> JournalRestoreEntry {
        let count = max(1, revisionCount)
        return JournalRestoreEntry(
            intake: Intake(
                id: id, category: "food", occurredAt: base, timeZoneIdentifier: "Europe/Berlin",
                meal: "breakfast", lifecycle: .active, currentRevision: count),
            revisions: (1...count).map { number in
                IntakeRevision(
                    intakeID: id, number: number, components: [oats("40")], productSnapshotID: nil,
                    changeReason: "created", createdAt: base.addingTimeInterval(TimeInterval(number) * 60))
            })
    }

    /// The first field where two encoded documents disagree, named as a key path such as
    /// `$.intakes[0].current_revision`. A round trip that is not byte-identical otherwise fails with two
    /// long blobs and no idea which field moved, so the failure says which one it was.
    func firstDifference(between left: Data, and right: Data) throws -> String? {
        let leftFields = try XCTUnwrap(try JSONSerialization.jsonObject(with: left) as? [String: Any])
        let rightFields = try XCTUnwrap(try JSONSerialization.jsonObject(with: right) as? [String: Any])
        return difference(leftFields, rightFields, path: "$")
    }

    func difference(_ left: Any, _ right: Any, path: String) -> String? {
        // The shape is compared before the value: a JSON object also casts to an array of any, so asking
        // about arrays first would read an object as a list of its values.
        if left is [String: Any] || right is [String: Any] {
            guard let left = left as? [String: Any], let right = right as? [String: Any] else {
                return "\(path) is an object in one document and not in the other"
            }
            for key in Set(left.keys).union(right.keys).sorted() {
                guard let leftValue = left[key], let rightValue = right[key] else {
                    return "\(path).\(key) is in only one of the two documents"
                }
                if let found = difference(leftValue, rightValue, path: "\(path).\(key)") { return found }
            }
            return nil
        }
        if left is [Any] || right is [Any] {
            guard let left = left as? [Any], let right = right as? [Any] else {
                return "\(path) is a list in one document and not in the other"
            }
            guard left.count == right.count else {
                return "\(path) holds \(left.count) items and \(right.count) items"
            }
            for index in left.indices {
                if let found = difference(left[index], right[index], path: "\(path)[\(index)]") { return found }
            }
            return nil
        }
        // Both sides are scalars, an explicit null included: it describes as "null" on either side.
        guard String(describing: left) != String(describing: right) else { return nil }
        return "\(path) is \(left) in one document and \(right) in the other"
    }
}

/// Restoring a journal export: the round trip, what comes back, and what is refused.
final class JournalImportTests: JournalImportTestCase {
    // MARK: The happy path

    func testExportImportExportRoundTripsToTheSameBytes() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let summary = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        XCTAssertEqual(summary.intakes, 2)
        XCTAssertEqual(summary.tombstones, 1)
        XCTAssertEqual(summary.favorites, 2)
        XCTAssertEqual(summary.products, 1)

        let again = try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: journal, favorites: favoritesStore, appVersion: appVersion, exportedAt: exportedAt))
        // Named before the assertion, because an assertion message is built in a closure that may not
        // throw, and reading the two documents back is a throwing call.
        let changedField = try firstDifference(between: data, and: again)
        XCTAssertEqual(
            again, data,
            "an import that changed a single field would show up here: "
                + (changedField ?? "no field differs, only the encoding"))
    }

    func testEveryRevisionOfAnEntryIsRestoredInOrderWithItsOwnTimestamps() throws {
        let data = try exportData(favorites: false)
        let target = try directory()
        let journal = try store(target)
        try JournalImporter.importExport(data, into: journal, favorites: nil)

        let revisions = try journal.revisions(of: oatsID)
        XCTAssertEqual(revisions.map(\.number), [1, 2])
        XCTAssertEqual(revisions.map(\.changeReason), ["created", "bigger bowl"])
        XCTAssertEqual(
            revisions.map(\.components.first?.amount),
            [Decimal(string: "37.5")!, Decimal(string: "55.5")!])
        XCTAssertEqual(revisions[0].createdAt, base)
        XCTAssertEqual(revisions[1].createdAt, base.addingTimeInterval(600))
        let restored = try journal.activeIntakes().first { $0.id == oatsID }
        XCTAssertEqual(restored?.currentRevision, 2)
        XCTAssertEqual(restored?.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(restored?.meal, "breakfast")
        XCTAssertEqual(restored?.occurredAt, base)
        XCTAssertNil(try journal.activeIntakes().first { $0.id == waterID }?.meal)
    }

    func testProductSnapshotsComeBackSoAnEntryNeedsNoCatalog() throws {
        let data = try exportData(favorites: false)
        let target = try directory()
        let journal = try store(target)
        try JournalImporter.importExport(data, into: journal, favorites: nil)
        let snapshot = try XCTUnwrap(try journal.product(snapshotID: "snap-oats-1"))
        XCTAssertEqual(snapshot.name, "Sample rolled oats")
        XCTAssertEqual(snapshot.barcode, "0000000000017")
        XCTAssertEqual(snapshot.catalogOrigin, "sample-catalog")
        XCTAssertEqual(
            try journal.revisions(of: oatsID).map(\.productSnapshotID), ["snap-oats-1", "snap-oats-1"])
    }

    func testADeletedEntryComesBackAsATombstoneAndNotAsALiveEntry() throws {
        let data = try exportData(favorites: false)
        let target = try directory()
        let journal = try store(target)
        try JournalImporter.importExport(data, into: journal, favorites: nil)

        XCTAssertFalse(try journal.activeIntakes().contains { $0.id == goneID })
        let deleted = try journal.deletedIntakes()
        XCTAssertEqual(deleted.map(\.id), [goneID])
        XCTAssertEqual(deleted.first?.currentRevision, 1)
        XCTAssertEqual(deleted.first?.occurredAt, base.addingTimeInterval(7200))
        XCTAssertEqual(deleted.first?.timeZoneIdentifier, "Europe/Berlin")
        // A re-export has to keep it out of the intakes again, or the next restore would revive it.
        let document = try JournalExporter.makeExport(
            store: journal, favorites: nil, appVersion: appVersion, exportedAt: exportedAt)
        XCTAssertEqual(document.tombstones.map(\.intakeID), [goneID])
        XCTAssertFalse(document.intakes.contains { $0.id == goneID })
    }

    func testFavoritesAreRestoredWithTheirExactDecimalText() throws {
        let data = try exportData()
        let target = try directory()
        let favoritesStore = try favorites(target)
        try JournalImporter.importExport(data, into: store(target), favorites: favoritesStore)

        let restored = try favoritesStore.list().sorted { $0.id < $1.id }
        XCTAssertEqual(restored.map(\.id), ["fav-oats-1", "fav-tea-1"])
        XCTAssertEqual(restored.map { $0.components.map(\.amountText) }, [["0.5"], ["250"]])
        XCTAssertEqual(restored.map(\.productSnapshotID), ["snap-oats-1", nil])
        XCTAssertEqual(restored.first?.displayName, "Sample oats")
        XCTAssertEqual(restored.first?.meal, "breakfast")
        XCTAssertEqual(restored.last?.components.first?.unitSymbol, "mL")
    }

    func testDecimalAmountsSurviveExactlyAndAreNeverReadAsBinaryFloats() throws {
        let data = try exportData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"amount\":\"55.5\""), text)
        XCTAssertTrue(text.contains("\"amount\":\"250\""), text)
        XCTAssertTrue(text.contains("\"amount\":\"0.5\""), text)
        XCTAssertFalse(text.contains("\"amount\":55.5"), "an amount must never be a JSON number")

        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)

        XCTAssertEqual(
            try journal.revisions(of: oatsID).last?.components.first?.amount, Decimal(string: "55.5"))
        XCTAssertEqual(
            try journal.revisions(of: waterID).first?.components.first?.amount, Decimal(string: "250"))
        XCTAssertEqual(try journal.revisions(of: waterID).first?.components.first?.unit, .mL)
        let again = try XCTUnwrap(
            String(
                data: try JournalExporter.encode(
                    try JournalExporter.makeExport(
                        store: journal, favorites: favoritesStore, appVersion: appVersion,
                        exportedAt: exportedAt)),
                encoding: .utf8))
        XCTAssertTrue(again.contains("\"amount\":\"55.5\""), again)
        XCTAssertTrue(again.contains("\"amount\":\"0.5\""), again)
    }

    func testTheSummaryCountsWhatWasRestored() throws {
        let target = try directory()
        let summary = try JournalImporter.importExport(
            try exportData(), into: store(target), favorites: try favorites(target))
        XCTAssertEqual(
            summary,
            JournalImportSummary(intakes: 2, revisions: 3, tombstones: 1, favorites: 2, products: 1))
    }

    func testAnImportSurvivesReopeningTheStoreFile() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        journal.close()
        favoritesStore.close()

        let reopened = try store(target)
        XCTAssertEqual(try reopened.activeIntakes().count, 2)
        XCTAssertEqual(try reopened.deletedIntakes().count, 1)
        XCTAssertEqual(try reopened.revisions(of: oatsID).count, 2)
        let reopenedFavorites = try favorites(target)
        XCTAssertEqual(try reopenedFavorites.list().count, 2)
        XCTAssertTrue(try reopened.pendingOutbox().isEmpty)
    }

    // MARK: What the importer refuses

    func testAnExportFromANewerSchemaVersionIsRefusedAndNothingIsWritten() throws {
        var root = try object(of: try exportData(favorites: false))
        root["schema_version"] = 2
        root["field_this_build_does_not_know"] = "something"
        let newer = try JSONSerialization.data(withJSONObject: root)

        let target = try directory()
        let journal = try store(target)
        XCTAssertThrowsError(try JournalImporter.importExport(newer, into: journal, favorites: nil)) { error in
            XCTAssertEqual(error as? JournalImportError, .unsupportedVersion)
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
    }

    func testTheSameVersionWrittenAsTextIsAccepted() throws {
        // A file that spells the version as "1" names the version this build reads, so it is not refused
        // for something the reader understands perfectly well.
        let data = Data(
            #"{"schema_version":"1","exported_at":"2024-01-15T09:15:00Z","app_version":"0.1.0","intakes":[],"tombstones":[],"favorites":[],"products":[]}"#.utf8)
        let target = try directory()
        let journal = try store(target)
        let summary = try JournalImporter.importExport(data, into: journal, favorites: nil)
        XCTAssertEqual(summary.intakes, 0)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    func testANonEmptyStoreIsRefusedRatherThanMerged() throws {
        let data = try exportData(favorites: false)
        let target = try directory()
        let journal = try store(target)
        // One entry that is not from the file: an import must not join two journals together.
        try journal.create(
            Intake(
                id: otherID, category: "food", occurredAt: base, timeZoneIdentifier: "UTC"),
            components: [water("100")], product: nil, now: base)

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: nil)) { error in
            XCTAssertEqual(error as? JournalImportError, .notEmpty)
        }
        // The store is exactly as it was: one entry, one revision, and its own queued work untouched.
        XCTAssertEqual(try journal.activeIntakes().map(\.id), [otherID])
        XCTAssertEqual(try journal.revisions(of: otherID).count, 1)
        XCTAssertEqual(try journal.pendingOutbox().count, 2)
    }

    func testAStoreThatOnlyHoldsATombstoneIsStillNotEmpty() throws {
        let data = try exportData(favorites: false)
        let target = try directory()
        let journal = try store(target)
        try journal.create(
            Intake(
                id: otherID, category: "food", occurredAt: base, timeZoneIdentifier: "UTC"),
            components: [water("100")], product: nil, now: base)
        try journal.delete(intakeID: otherID, now: base)

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: nil)) { error in
            XCTAssertEqual(error as? JournalImportError, .notEmpty)
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertEqual(try journal.deletedIntakes().count, 1)
    }

    func testAMalformedFileIsRejectedAndTheStoreIsLeftUntouched() throws {
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let broken = [
            Data("this is not json at all".utf8),
            Data("[]".utf8),
            Data(#"{"schema_version":1,"exported_at":"not a date"}"#.utf8),
        ]
        for bytes in broken {
            do {
                _ = try JournalImporter.importExport(bytes, into: journal, favorites: favoritesStore)
                XCTFail(
                    "a file that is not a journal export must be refused: "
                        + String(decoding: bytes, as: UTF8.self))
            } catch let error as JournalImportError {
                guard case .malformed = error else {
                    return XCTFail("expected a malformed file, got \(error)")
                }
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
        XCTAssertTrue(try journal.pendingOutbox().isEmpty)
    }

    func testACorruptFileIsRejectedBeforeAnythingIsWritten() throws {
        // A revision that points at a snapshot the document never defines: the amounts would have to come
        // from somewhere, and inventing them is what this refuses.
        var root = try object(of: try exportData(favorites: false))
        var intakes = try XCTUnwrap(root["intakes"] as? [[String: Any]])
        var first = intakes[0]
        var revisions = try XCTUnwrap(first["revisions"] as? [[String: Any]])
        revisions[0]["product_snapshot_id"] = "snap-that-is-not-in-the-file"
        first["revisions"] = revisions
        intakes[0] = first
        root["intakes"] = intakes
        root["products"] = []
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: favoritesStore)
            XCTFail("a dangling product snapshot must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }

    func testAnAmountThatIsNotExactDecimalTextIsRejectedRatherThanRounded() throws {
        var root = try object(of: try exportData(favorites: false))
        var intakes = try XCTUnwrap(root["intakes"] as? [[String: Any]])
        var first = intakes[0]
        var revisions = try XCTUnwrap(first["revisions"] as? [[String: Any]])
        var components = try XCTUnwrap(revisions[0]["components"] as? [[String: Any]])
        components[0]["amount"] = "37,5"
        revisions[0]["components"] = components
        first["revisions"] = revisions
        intakes[0] = first
        root["intakes"] = intakes

        let target = try directory()
        let journal = try store(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: nil)
            XCTFail("an amount that is not decimal text must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    func testARevisionWithNoAmountIsRefusedRatherThanStoredAsZero() throws {
        // "Not known" and "none" are different answers, and a store that cannot hold the first must say
        // so rather than write a 0 that would later read as a real measurement.
        let document = JournalExport(
            exportedAt: exportedAt, appVersion: appVersion,
            intakes: [
                JournalExportIntake(
                    id: oatsID, category: "food", occurredAt: base, timeZoneIdentifier: "UTC", meal: nil,
                    note: nil, currentRevision: 1,
                    revisions: [
                        JournalExportRevision(
                            number: 1, createdAt: base, changeReason: "created", productSnapshotID: nil,
                            provenance: nil,
                            components: [
                                JournalExportComponent(
                                    componentID: "oats", name: "Sample rolled oats", amount: nil, unit: "g",
                                    valueState: .unknown)
                            ])
                    ])
            ],
            tombstones: [], favorites: [], products: [])
        let target = try directory()
        let journal = try store(target)
        do {
            _ = try JournalImporter.importExport(
                try JournalExporter.encode(document), into: journal, favorites: nil)
            XCTFail("a component with no amount must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    // MARK: Delivery

    func testAnImportQueuesNoOutboxOperationsAndNoProjections() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        try JournalImporter.importExport(data, into: journal, favorites: try favorites(target))
        XCTAssertTrue(try journal.pendingOutbox().isEmpty, "a restored entry was already delivered once")
        XCTAssertTrue(try journal.projections(of: oatsID).isEmpty)
        XCTAssertTrue(try journal.projections(of: waterID).isEmpty)
        journal.close()

        let reopened = try store(target)
        XCTAssertEqual(try reopened.revisions(of: oatsID).count, 2)
        XCTAssertTrue(try reopened.pendingOutbox().isEmpty, "the file itself holds no delivery work")
    }

    func testAnEditAfterAnImportIsStillQueuedAsANewDelivery() throws {
        // The importer's silence is not the store's: the normal path queues what it always did.
        let target = try directory()
        let journal = try store(target)
        try JournalImporter.importExport(try exportData(favorites: false), into: journal, favorites: nil)
        try journal.edit(
            intakeID: waterID, components: [water("300")], product: nil, changeReason: "more",
            now: base.addingTimeInterval(9000))
        XCTAssertEqual(try journal.revisions(of: waterID).map(\.number), [1, 2])
        XCTAssertEqual(try journal.pendingOutbox().count, 2)
    }

    // MARK: Inconsistent documents

    func testProvenanceThatNamesADifferentSnapshotIsRejected() throws {
        // A revision says it used snapshot A and carries the details of snapshot B. Accepting that would
        // attach A to the revision and quietly throw B away on the next export, which is a file lying
        // about where the amounts came from.
        var root = try object(of: try exportData(favorites: false))
        var intakes = try XCTUnwrap(root["intakes"] as? [[String: Any]])
        var first = intakes[0]
        var revisions = try XCTUnwrap(first["revisions"] as? [[String: Any]])
        var provenance = try XCTUnwrap(revisions[0]["provenance"] as? [String: Any])
        provenance["snapshot_id"] = "snap-a-different-product"
        revisions[0]["provenance"] = provenance
        first["revisions"] = revisions
        intakes[0] = first
        root["intakes"] = intakes

        let target = try directory()
        let journal = try store(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: nil)
            XCTFail("provenance for a snapshot the revision does not use must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertNil(try journal.product(snapshotID: "snap-a-different-product"))
    }

    func testProvenanceForARecordedEntryByHandIsStillAccepted() throws {
        // The everyday case: no product at all, so no provenance, which is what the export writes and what
        // an entry typed in by hand looks like after a round trip.
        let target = try directory()
        let journal = try store(target)
        let summary = try JournalImporter.importExport(
            try exportData(favorites: false), into: journal, favorites: nil)
        XCTAssertEqual(summary.intakes, 2)
        XCTAssertEqual(
            try journal.revisions(of: waterID).first?.productSnapshotID, nil)
    }

    func testAFavoriteWithAZeroAmountIsRejected() throws {
        // A favorite is a template to repeat. "0 g of oats" asks the person to eat nothing, and repeating it
        // would create an intake that claims a measurement the template never made.
        try assertFavoriteRefused(amountText: "0", why: "zero is not a quantity")
    }

    func testAFavoriteWithANegativeAmountIsRejected() throws {
        // "-5 g" is not a smaller portion, it is a subtraction. Storing it would show a negative amount on the
        // favorites row and ask for it on the intake the repeat creates.
        try assertFavoriteRefused(amountText: "-5", why: "a negative amount is not a quantity")
    }

    func testAFavoriteThatNamesOneComponentTwiceIsRejected() throws {
        var root = try object(of: try exportData())
        var favoriteList = try XCTUnwrap(root["favorites"] as? [[String: Any]])
        let index = try XCTUnwrap(favoriteList.firstIndex { $0["id"] as? String == "fav-tea-1" })
        var components = try XCTUnwrap(favoriteList[index]["components"] as? [[String: Any]])
        components.append(components[0])
        favoriteList[index]["components"] = components
        root["favorites"] = favoriteList

        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: favoritesStore)
            XCTFail("a favorite naming one component twice must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }

    /// One favorite with the given amount text, refused and with nothing written.
    private func assertFavoriteRefused(amountText: String, why: String, line: UInt = #line) throws {
        var root = try object(of: try exportData())
        var favoriteList = try XCTUnwrap(root["favorites"] as? [[String: Any]])
        let index = try XCTUnwrap(favoriteList.firstIndex { $0["id"] as? String == "fav-tea-1" })
        var components = try XCTUnwrap(favoriteList[index]["components"] as? [[String: Any]])
        components[0]["amount"] = amountText
        favoriteList[index]["components"] = components
        root["favorites"] = favoriteList

        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: favoritesStore)
            XCTFail("a favorite with \"\(amountText)\" must be refused, \(why)", line: line)
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)", line: line)
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty, line: line)
        XCTAssertTrue(try favoritesStore.list().isEmpty, line: line)
    }

    func testAFavoriteWithNoComponentsIsRejected() throws {
        // A favorite with nothing in it cannot be repeated: there are no amounts to repeat, so the row would
        // show a name and no numbers, and the intake it created would claim nothing at all.
        var root = try object(of: try exportData())
        var favoriteList = try XCTUnwrap(root["favorites"] as? [[String: Any]])
        let index = try XCTUnwrap(favoriteList.firstIndex { $0["id"] as? String == "fav-tea-1" })
        favoriteList[index]["components"] = []
        root["favorites"] = favoriteList

        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: favoritesStore)
            XCTFail("a favorite with no components must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }

    func testAnEntryWithoutATimeZoneIsRejected() throws {
        // The time zone is what says when an entry happened where the person was. An empty string, or a name
        // no calendar knows, would be stored as text and read back as a zone the app cannot use, so the file
        // is refused instead.
        for identifier in ["", "Middle/Earth"] {
            var root = try object(of: try exportData(favorites: false))
            var intakes = try XCTUnwrap(root["intakes"] as? [[String: Any]])
            intakes[0]["time_zone"] = identifier
            root["intakes"] = intakes

            let target = try directory()
            let journal = try store(target)
            do {
                _ = try JournalImporter.importExport(
                    try JSONSerialization.data(withJSONObject: root), into: journal, favorites: nil)
                XCTFail("a time zone of \"\(identifier)\" must be refused")
            } catch let error as JournalImportError {
                guard case .corrupt = error else {
                    return XCTFail("expected a corrupt file, got \(error)")
                }
            }
            XCTAssertTrue(try journal.activeIntakes().isEmpty)
        }
    }

    func testATombstoneWithoutATimeZoneIsRejected() throws {
        var root = try object(of: try exportData(favorites: false))
        var tombstones = try XCTUnwrap(root["tombstones"] as? [[String: Any]])
        tombstones[0]["time_zone"] = ""
        root["tombstones"] = tombstones

        let target = try directory()
        let journal = try store(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: nil)
            XCTFail("a tombstone with no time zone must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
    }

    func testACurrentRevisionTheRevisionsDoNotAddUpToIsRejected() throws {
        // The current revision has to be the last one there is. Checking that by walking the list the file
        // holds, rather than by building the range it claims, also keeps a hand-edited number from turning
        // into an enormous allocation: the file below claims two billion revisions and carries two.
        for claimed in [3, 2_000_000_000] {
            var root = try object(of: try exportData(favorites: false))
            var intakes = try XCTUnwrap(root["intakes"] as? [[String: Any]])
            intakes[0]["current_revision"] = claimed
            root["intakes"] = intakes

            let target = try directory()
            let journal = try store(target)
            do {
                _ = try JournalImporter.importExport(
                    try JSONSerialization.data(withJSONObject: root), into: journal, favorites: nil)
                XCTFail("a current revision of \(claimed) over two revisions must be refused")
            } catch let error as JournalImportError {
                guard case .corrupt = error else {
                    return XCTFail("expected a corrupt file, got \(error)")
                }
            }
            XCTAssertTrue(try journal.activeIntakes().isEmpty)
        }
    }

    func testRevisionsOutOfOrderAreRejected() throws {
        var root = try object(of: try exportData(favorites: false))
        var intakes = try XCTUnwrap(root["intakes"] as? [[String: Any]])
        var first = intakes[0]
        var revisions = try XCTUnwrap(first["revisions"] as? [[String: Any]])
        revisions.swapAt(0, 1)
        first["revisions"] = revisions
        intakes[0] = first
        root["intakes"] = intakes

        let target = try directory()
        let journal = try store(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: nil)
            XCTFail("revisions that do not read 1, 2 in order must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    func testAFavoriteWithAUnitThisBuildDoesNotKnowIsRejected() throws {
        // The favorites store keeps a unit symbol as text and never parses it, so an unusable symbol would
        // be stored happily and only fail later, when the person tries to repeat the favorite and the
        // amounts come back empty. A template that cannot be repeated is not worth restoring.
        var root = try object(of: try exportData())
        var favoriteList = try XCTUnwrap(root["favorites"] as? [[String: Any]])
        let index = try XCTUnwrap(favoriteList.firstIndex { $0["id"] as? String == "fav-tea-1" })
        var components = try XCTUnwrap(favoriteList[index]["components"] as? [[String: Any]])
        components[0]["unit"] = "cupful"
        favoriteList[index]["components"] = components
        root["favorites"] = favoriteList

        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        do {
            _ = try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: favoritesStore)
            XCTFail("a favorite with an unknown unit must be refused")
        } catch let error as JournalImportError {
            guard case .corrupt = error else {
                return XCTFail("expected a corrupt file, got \(error)")
            }
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }
}
