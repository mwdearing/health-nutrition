import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Restoring a journal export, on real on-disk stores in unique temporary directories.
final class JournalImportTests: XCTestCase {
    private let oatsID = "1f0c9d2a-6b3e-4a7f-9c5d-0e2b6f8a1d33"
    private let waterID = "7d4a1c55-9e2b-4f60-8a3d-5c1b0f7e2a94"
    private let goneID = "2b9e4c07-51d8-4a63-8f2e-6c3a9d05b7e1"
    private let otherID = "5e2a7c18-4b93-4d2e-9f61-8c5d3a7e0b42"
    /// A whole second, so the exported text carries no fraction and the round trip is exact.
    private let exportedAt = Date(timeIntervalSince1970: 1_705_310_100)
    private let base = Date(timeIntervalSince1970: 1_705_264_200)
    private let appVersion = "0.1.0"

    // MARK: Fixtures

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func store(_ directory: URL) throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func favorites(_ directory: URL) throws -> SwiftDataFavoritesStore {
        try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
    }

    private func oats(_ grams: String) -> IntakeComponent {
        IntakeComponent(
            componentID: "oats", name: "Sample rolled oats", amount: Decimal(string: grams)!, unit: .g)
    }

    private func water(_ millilitres: String) -> IntakeComponent {
        IntakeComponent(
            componentID: "water", name: "Sample water", amount: Decimal(string: millilitres)!, unit: .mL)
    }

    private func product() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snap-oats-1", productID: "product-oats", name: "Sample rolled oats",
            brand: "Sample Brand", barcode: "0000000000017", labelBasis: "per100g",
            catalogOrigin: "sample-catalog", catalogVersion: "1")
    }

    /// A journal with two live entries, one of them edited once, and one entry already deleted.
    private func filledStore(_ directory: URL) throws -> SwiftDataJournalStore {
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

    private func filledFavorites(_ directory: URL) throws -> SwiftDataFavoritesStore {
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
    private func exportData(from source: URL? = nil, favorites included: Bool = true) throws -> Data {
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
    private func object(of data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

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
        XCTAssertEqual(again, data, "an import that changed a single field would show up here")
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
}
