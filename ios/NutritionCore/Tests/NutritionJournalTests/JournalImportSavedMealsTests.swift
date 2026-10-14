import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// An in-memory saved meals list with a receipt, as the app's store keeps one, that can fail a restore.
private final class MemorySavedMeals: JournalSavedMealsStore, @unchecked Sendable {
    struct Failure: Error {}
    var meals: [JournalSavedMeal]
    var receipt: String?
    var failRestore = false

    init(_ meals: [JournalSavedMeal] = []) { self.meals = meals }

    func journalSavedMeals() throws -> [JournalSavedMeal] { meals }
    func restoreJournalSavedMeals(_ meals: [JournalSavedMeal], receipt: String) throws {
        if failRestore { throw Failure() }
        self.meals = meals
        self.receipt = receipt
    }
    func hasSavedMealsRestoreReceipt(_ receipt: String) throws -> Bool { self.receipt == receipt }
    func removeSavedMealsRestoreReceipt(_ receipt: String) throws { if self.receipt == receipt { self.receipt = nil } }
    func clearRestoredSavedMeals() throws {
        meals = []
        receipt = nil
    }
}

/// A favorites store whose restore always fails, after the saved meals were written.
private final class FailingFavorites: FavoritesStore, FavoritesRestoreTarget, @unchecked Sendable {
    func add(_ favorite: FavoriteTemplate) throws {}
    func remove(id: String) throws {}
    func list() throws -> [FavoriteTemplate] { [] }
    func contains(id: String) throws -> Bool { false }
    func close() {}
    func restore(_ favorites: [FavoriteTemplate]) throws { throw FavoritesError.injectedSaveFailure }
}

/// Saved meals in a version 4 export: written in the list's order with the products their items use, and
/// restored in the second phase with the favorites, under the same resume flag and receipts (#118).
final class JournalImportSavedMealsTests: JournalImportTestCase {
    private func template(_ id: String, name: String, amount: String = "40", snapshotID: String? = nil) -> FavoriteTemplate {
        FavoriteTemplate(
            id: id, displayName: name, category: "food",
            components: [FavoriteComponent(componentID: "oats", name: name, amountText: amount, unitSymbol: "g")],
            productSnapshotID: snapshotID)
    }

    /// Two meals, newest first; the second's item repeats the oats product, which the filled journal uses.
    private func sampleMeals() -> [JournalSavedMeal] {
        [
            JournalSavedMeal(id: "meal-2", name: "Lunch box", meal: nil, items: [template("item-3", name: "Sample apple")]),
            JournalSavedMeal(
                id: "meal-1", name: "Usual breakfast", meal: .breakfast,
                items: [template("item-1", name: "Sample oats", snapshotID: "snap-oats-1"), template("item-2", name: "Sample milk")]),
        ]
    }

    private func savedMealsExport() throws -> Data {
        let directory = try self.directory()
        return try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: try filledStore(directory), favorites: try filledFavorites(directory),
                savedMeals: MemorySavedMeals(sampleMeals()), appVersion: appVersion, exportedAt: exportedAt))
    }

    private func fields(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnExportCarriesSavedMealsInOrderAndRestoresThem() throws {
        let data = try savedMealsExport()
        let root = try fields(data)
        XCTAssertEqual(root["schema_version"] as? Int, 4)
        let exported = try XCTUnwrap(root["saved_meals"] as? [[String: Any]])
        XCTAssertEqual(exported.map { $0["id"] as? String }, ["meal-2", "meal-1"])
        XCTAssertEqual(exported.map { $0["meal"] as? String }, [nil, "breakfast"])

        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        let summary = try JournalImporter.importExport(
            data, into: journal, favorites: try favorites(target), savedMeals: savedMeals)
        XCTAssertEqual(summary.savedMeals, 2)
        XCTAssertEqual(savedMeals.meals, sampleMeals())
        XCTAssertNil(savedMeals.receipt, "a finished restore forgets its receipt")
        XCTAssertNil(try journal.restoreInProgressDigest())
    }

    func testAnItemsProductIsExportedEvenWhenNoEntryUsesIt() throws {
        let directory = try self.directory()
        let journal = try store(directory)
        // The product is stored by an entry that is then deleted, so only the saved meal still refers to it.
        let gone = Intake(id: goneID, category: "food", occurredAt: base, timeZoneIdentifier: "Europe/Berlin")
        try journal.create(gone, components: [oats("20")], product: product(), now: base)
        try journal.delete(intakeID: goneID, now: base.addingTimeInterval(60))
        let meal = JournalSavedMeal(
            id: "meal-1", name: "Usual breakfast", meal: .breakfast,
            items: [template("item-1", name: "Sample oats", snapshotID: "snap-oats-1")])

        let document = try JournalExporter.makeExport(
            store: journal, savedMeals: MemorySavedMeals([meal]), appVersion: appVersion, exportedAt: exportedAt)
        XCTAssertEqual(document.products.map(\.snapshotID), ["snap-oats-1"])
        XCTAssertEqual(document.savedMeals.first?.items.first?.productSnapshotID, "snap-oats-1")
    }

    func testSavedMealsInAnEarlierVersionAreRefused() throws {
        var root = try fields(try savedMealsExport())
        root["schema_version"] = 3
        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try JournalImporter.importExport(
            data, into: try store(try directory()), favorites: nil, savedMeals: MemorySavedMeals())) {
            guard let error = $0 as? JournalImportError, case .malformed = error else { return XCTFail("\($0)") }
        }
    }

    func testAVersion4FileWithoutSavedMealsIsRefused() throws {
        var root = try fields(try savedMealsExport())
        root.removeValue(forKey: "saved_meals")
        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try JournalImporter.importExport(
            data, into: try store(try directory()), favorites: nil, savedMeals: MemorySavedMeals())) {
            guard let error = $0 as? JournalImportError, case .malformed = error else { return XCTFail("\($0)") }
        }
    }

    func testAMealTheAppWouldRefuseToSaveIsRefusedAndNothingIsWritten() throws {
        let base = try fields(try savedMealsExport())
        let edits: [(String, ([String: Any]) -> [String: Any])] = [
            ("a repeated name", { meal in var meal = meal; meal["name"] = " lunch BOX "; return meal }),
            ("an unknown meal", { meal in var meal = meal; meal["meal"] = "brunch"; return meal }),
            ("no items", { meal in var meal = meal; meal["items"] = [[String: Any]](); return meal }),
            ("a long name", { meal in var meal = meal; meal["name"] = String(repeating: "a", count: 61); return meal }),
            ("an item with its own meal", { meal in
                var meal = meal
                var items = meal["items"] as? [[String: Any]] ?? []
                items[0]["meal"] = "lunch"
                meal["items"] = items
                return meal
            }),
        ]
        for (label, edit) in edits {
            var root = base
            var meals = try XCTUnwrap(root["saved_meals"] as? [[String: Any]])
            meals[1] = edit(meals[1])
            root["saved_meals"] = meals
            let data = try JSONSerialization.data(withJSONObject: root)
            let target = try directory()
            let journal = try store(target)
            let savedMeals = MemorySavedMeals()
            XCTAssertThrowsError(
                try JournalImporter.importExport(data, into: journal, favorites: try favorites(target), savedMeals: savedMeals),
                label)
            XCTAssertEqual(try journal.activeIntakes(), [], label)
            XCTAssertEqual(savedMeals.meals, [], label)
        }
    }

    func testSavedMealsNeedAStoreToGoTo() throws {
        let target = try directory()
        XCTAssertThrowsError(try JournalImporter.importExport(
            try savedMealsExport(), into: try store(target), favorites: try favorites(target))) {
            guard let error = $0 as? JournalImportError, case .corrupt = error else { return XCTFail("\($0)") }
        }
    }

    func testAListThatAlreadyHoldsSavedMealsIsNotMergedInto() throws {
        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals([JournalSavedMeal(id: "mine", name: "Mine", meal: nil, items: [template("x", name: "X")])])
        XCTAssertThrowsError(try JournalImporter.importExport(
            try savedMealsExport(), into: journal, favorites: try favorites(target), savedMeals: savedMeals)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertEqual(try journal.activeIntakes(), [])
        XCTAssertEqual(savedMeals.meals.map(\.id), ["mine"])
    }

    func testAFailedFavoritesWriteEmptiesTheSavedMealsAndTheJournalAgain() throws {
        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        XCTAssertThrowsError(try JournalImporter.importExport(
            try savedMealsExport(), into: journal, favorites: FailingFavorites(), savedMeals: savedMeals))
        XCTAssertEqual(savedMeals.meals, [])
        XCTAssertNil(savedMeals.receipt)
        XCTAssertEqual(try journal.activeIntakes(), [])
        XCTAssertNil(try journal.restoreInProgressDigest())
    }

    func testAFailedSavedMealsWriteEmptiesTheJournalAgain() throws {
        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        savedMeals.failRestore = true
        let favoritesStore = try favorites(target)
        XCTAssertThrowsError(try JournalImporter.importExport(
            try savedMealsExport(), into: journal, favorites: favoritesStore, savedMeals: savedMeals))
        XCTAssertEqual(try journal.activeIntakes(), [])
        XCTAssertEqual(try favoritesStore.list(), [], "the favorites come after the saved meals, so none were written")
    }

    /// A stop after the journal's save leaves the flag and the journal; importing the same file again writes
    /// the saved meals and the favorites.
    func testAStopAfterTheJournalIsFinishedWithBothParts() throws {
        let data = try savedMealsExport()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let savedMeals = MemorySavedMeals()
        try journal.markRestoreInProgress(fileDigest: JournalImporter.fileDigest(data))
        _ = try journal.restore(try JournalImporter.makePlan(try JournalImporter.readDocument(data)))

        let summary = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore, savedMeals: savedMeals)
        XCTAssertEqual(summary.savedMeals, 2)
        XCTAssertEqual(savedMeals.meals, sampleMeals())
        XCTAssertEqual(try favoritesStore.list().count, 2)
        XCTAssertNil(try journal.restoreInProgressDigest())
    }

    /// A stop between the saved meals' write and the favorites' leaves only the favorites to write.
    func testAStopBetweenTheTwoPartsWritesOnlyTheFavorites() throws {
        let data = try savedMealsExport()
        let digest = JournalImporter.fileDigest(data)
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let plan = try JournalImporter.makePlan(try JournalImporter.readDocument(data))
        let savedMeals = MemorySavedMeals()
        try journal.markRestoreInProgress(fileDigest: digest)
        _ = try journal.restore(plan)
        try savedMeals.restoreJournalSavedMeals(plan.savedMeals, receipt: digest)
        // Edited since: a resume that wrote the list again would bring this edit back.
        savedMeals.meals[0].name = "Packed lunch"

        _ = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore, savedMeals: savedMeals)
        XCTAssertEqual(savedMeals.meals.first?.name, "Packed lunch", "a part with its receipt is not written again")
        XCTAssertEqual(try favoritesStore.list().count, 2)
        XCTAssertNil(savedMeals.receipt)
    }

    /// A file with saved meals and no favorites is covered by the flag as well.
    func testAFileWithSavedMealsAndNoFavoritesResumes() throws {
        let directory = try self.directory()
        let data = try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: try filledStore(directory), savedMeals: MemorySavedMeals(sampleMeals()), appVersion: appVersion,
                exportedAt: exportedAt))
        let target = try self.directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        try journal.markRestoreInProgress(fileDigest: JournalImporter.fileDigest(data))
        _ = try journal.restore(try JournalImporter.makePlan(try JournalImporter.readDocument(data)))

        _ = try JournalImporter.importExport(data, into: journal, favorites: nil, savedMeals: savedMeals)
        XCTAssertEqual(savedMeals.meals, sampleMeals())
        XCTAssertNil(try journal.restoreInProgressDigest())
    }

    /// A flag that outlived both parts is a leftover: the list the person changed since is not written again.
    func testAFlagOutlivingBothPartsIsRefused() throws {
        let data = try savedMealsExport()
        let digest = JournalImporter.fileDigest(data)
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let plan = try JournalImporter.makePlan(try JournalImporter.readDocument(data))
        let savedMeals = MemorySavedMeals()
        try journal.markRestoreInProgress(fileDigest: digest)
        _ = try journal.restore(plan)
        try savedMeals.restoreJournalSavedMeals(plan.savedMeals, receipt: digest)
        try favoritesStore.restore(plan.favorites, receipt: digest)
        savedMeals.meals = []

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: favoritesStore, savedMeals: savedMeals)) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertEqual(savedMeals.meals, [])
    }
}
