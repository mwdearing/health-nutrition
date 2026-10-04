import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// What a restore does to the nutrient values a product snapshot states. A document does not carry
/// them, so the only values an import may act on are the ones the store already holds.
final class JournalImportNutrientsTests: JournalImportTestCase {
    func testARestoredSnapshotKeepsTheNutrientValuesThisStoreAlreadyHolds() throws {
        // The document names the product a revision used and where it came from; it does not carry what
        // that product states. A store that already knows the snapshot has those values, so a restore
        // keeps them exactly rather than writing an empty set over them and reporting success.
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        try journal.insertProductSnapshotForTesting(product())
        let favoritesStore = try favorites(target)
        let summary = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore)
        XCTAssertEqual(summary.products, 1)

        let snapshot = try XCTUnwrap(try journal.product(snapshotID: "snap-oats-1"))
        XCTAssertEqual(snapshot.nutrients, sampleNutrients)
        XCTAssertEqual(snapshot.value(for: "energy"), .known(Decimal(string: "380")!, .kcal))
        XCTAssertEqual(snapshot.value(for: "fibre"), .unknown)
        // The identity still comes from the file, so the journal reads the same product as before.
        XCTAssertEqual(snapshot.productID, "product-oats")
        XCTAssertEqual(snapshot.barcode, "0000000000017")

        let changedField = try firstDifference(
            between: data,
            and: try JournalExporter.encode(
                try JournalExporter.makeExport(
                    store: journal, favorites: favoritesStore, appVersion: appVersion,
                    exportedAt: exportedAt)))
        XCTAssertNil(changedField, "keeping the stored nutrients must not change what an export writes")
    }

    func testAFreshStoreGetsTheSnapshotWithNoValuesOfItsOwn() throws {
        // Nothing to keep, and nothing invented either: the file says which product it is, and that is all
        // this store learns.
        let target = try directory()
        let journal = try store(target)
        try JournalImporter.importExport(try exportData(favorites: false), into: journal, favorites: nil)
        let snapshot = try XCTUnwrap(try journal.product(snapshotID: "snap-oats-1"))
        XCTAssertTrue(snapshot.nutrients.isEmpty)
        XCTAssertEqual(snapshot.name, "Sample rolled oats")
    }

    func testASnapshotWhoseValuesDisagreeWithTheStoredOnesIsStillRefused() throws {
        // Keeping the stored values is not a licence to accept a file that describes a different product
        // under the same snapshot id: the identity still has to match. The name is changed in the products
        // list *and* in the revision's own provenance, so the file stays consistent with itself and the
        // refusal comes from the store's snapshot rule rather than from the file contradicting itself.
        var root = try object(of: try exportData(favorites: false))
        var products = try XCTUnwrap(root["products"] as? [[String: Any]])
        products[0]["name"] = "Sample muesli"
        root["products"] = products
        var intakes = try XCTUnwrap(root["intakes"] as? [[String: Any]])
        for index in intakes.indices {
            var revisions = try XCTUnwrap(intakes[index]["revisions"] as? [[String: Any]])
            for revisionIndex in revisions.indices {
                guard var provenance = revisions[revisionIndex]["provenance"] as? [String: Any] else {
                    continue
                }
                provenance["name"] = "Sample muesli"
                revisions[revisionIndex]["provenance"] = provenance
            }
            intakes[index]["revisions"] = revisions
        }
        root["intakes"] = intakes

        let target = try directory()
        let journal = try store(target)
        try journal.insertProductSnapshotForTesting(product())
        XCTAssertThrowsError(
            try JournalImporter.importExport(
                try JSONSerialization.data(withJSONObject: root), into: journal, favorites: nil)
        ) { error in
            XCTAssertEqual(error as? JournalError, .snapshotConflict("snap-oats-1"))
        }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertEqual(try journal.product(snapshotID: "snap-oats-1")?.nutrients, sampleNutrients)
    }

    func testASnapshotWhoseStoredValuesDifferFromTheOnesBeingRestoredIsStillAConflict() throws {
        // A document carries no nutrient values, so this case cannot come from an export: it is the rule
        // itself, checked by handing the store a plan whose snapshot states values the stored row does not.
        // Silently keeping the stored ones would hide a plan that disagrees with the store.
        let target = try directory()
        let journal = try store(target)
        try journal.insertProductSnapshotForTesting(product())

        var different = product()
        different.nutrients = ["energy": .known(Decimal(string: "111")!, .kcal)]
        XCTAssertThrowsError(
            try journal.restore(
                JournalRestorePlan(entries: [], tombstones: [], products: [different], favorites: []))
        ) { error in
            XCTAssertEqual(error as? JournalError, .snapshotConflict("snap-oats-1"))
        }
        XCTAssertEqual(try journal.product(snapshotID: "snap-oats-1")?.nutrients, sampleNutrients)
    }

    func testASnapshotThatStatesValuesWhereTheStoreHasNoneIsFilledIn() throws {
        // The other half of the same rule: a stored row with no values is not a disagreement, it is a
        // snapshot this store knows less about than the plan does.
        let target = try directory()
        let journal = try store(target)
        var bare = product()
        bare.nutrients = [:]
        try journal.insertProductSnapshotForTesting(bare)

        _ = try journal.restore(
            JournalRestorePlan(entries: [], tombstones: [], products: [product()], favorites: []))
        XCTAssertEqual(try journal.product(snapshotID: "snap-oats-1")?.nutrients, sampleNutrients)
    }
}
