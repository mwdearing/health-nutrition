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
    /// Makes the undo's clear fail, as a saved meal written by another window would at that moment.
    var failClear = false
    /// Runs as a restore begins, as a meal saved in another window at that moment would.
    var beforeRestore: (MemorySavedMeals) -> Void = { _ in }

    init(_ meals: [JournalSavedMeal] = []) { self.meals = meals }

    func journalSavedMeals() throws -> [JournalSavedMeal] { meals }
    func restoreJournalSavedMeals(_ meals: [JournalSavedMeal], receipt: String) throws {
        beforeRestore(self)
        if failRestore { throw Failure() }
        guard self.meals.isEmpty || self.meals == meals else { throw JournalImportError.savedMealsNotEmpty }
        self.meals = meals
        self.receipt = receipt
    }
    func hasSavedMealsRestoreReceipt(_ receipt: String) throws -> Bool { self.receipt == receipt }
    func removeSavedMealsRestoreReceipt(_ receipt: String) throws { if self.receipt == receipt { self.receipt = nil } }
    func clearRestoredSavedMeals(_ meals: [JournalSavedMeal]) throws {
        if failClear { throw Failure() }
        guard self.meals == meals else { throw JournalImportError.savedMealsNotEmpty }
        self.meals = []
        receipt = nil
    }
}

/// A favorites store whose restore always fails, after the saved meals were written.
private final class FailingFavorites: FavoritesStore, FavoritesRestoreTarget, @unchecked Sendable {
    /// Runs before the failure, as another window writing in between would.
    var beforeFailing: () -> Void = {}
    func add(_ favorite: FavoriteTemplate) throws {}
    func remove(id: String) throws {}
    func list() throws -> [FavoriteTemplate] { [] }
    func contains(id: String) throws -> Bool { false }
    func close() {}
    func restore(_ favorites: [FavoriteTemplate]) throws {
        beforeFailing()
        throw FavoritesError.injectedSaveFailure
    }
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
                savedMeals: MemorySavedMeals(sampleMeals()), goals: InMemoryGoalStore(), appVersion: appVersion, exportedAt: exportedAt))
    }

    private func fields(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnExportCarriesSavedMealsInOrderAndRestoresThem() throws {
        let data = try savedMealsExport()
        let root = try fields(data)
        XCTAssertEqual(root["schema_version"] as? Int, JournalExport.currentSchemaVersion)
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
            store: journal, savedMeals: MemorySavedMeals([meal]), goals: InMemoryGoalStore(), appVersion: appVersion, exportedAt: exportedAt)
        XCTAssertEqual(document.products.map(\.snapshotID), ["snap-oats-1"])
        XCTAssertEqual(document.savedMeals.first?.items.first?.productSnapshotID, "snap-oats-1")
    }

    func testSavedMealsInAnEarlierVersionAreRefused() throws {
        var root = try fields(try savedMealsExport())
        root["schema_version"] = 3
        root.removeValue(forKey: "goals")
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
            ("an empty name", { meal in var meal = meal; meal["name"] = ""; return meal }),
            ("an item with no components", { meal in
                var meal = meal
                var items = meal["items"] as? [[String: Any]] ?? []
                items[0]["components"] = [[String: Any]]()
                meal["items"] = items
                return meal
            }),
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

    /// A saved meal's item is a favorite template, so an empty id, display name or category is refused as malformed
    /// by shape validation, naming the field, and nothing is written (#72).
    func testASavedMealItemWithAnEmptyRequiredFieldIsRefusedAndNothingIsWritten() throws {
        let base = try fields(try savedMealsExport())
        for field in ["id", "display_name", "category"] {
            var root = base
            var meals = try XCTUnwrap(root["saved_meals"] as? [[String: Any]], field)
            // The fixture's second meal has items; guard the indexes so a changed fixture fails, not crashes.
            guard meals.count > 1, var items = meals[1]["items"] as? [[String: Any]], !items.isEmpty else {
                return XCTFail("the fixture needs a second saved meal with an item")
            }
            items[0][field] = ""
            meals[1]["items"] = items
            root["saved_meals"] = meals
            let target = try directory()
            let journal = try store(target)
            let favoritesStore = try favorites(target)
            let savedMeals = MemorySavedMeals()
            XCTAssertThrowsError(
                try JournalImporter.importExport(
                    try JSONSerialization.data(withJSONObject: root), into: journal, favorites: favoritesStore,
                    savedMeals: savedMeals),
                field
            ) { error in
                guard case .malformed(let reason) = error as? JournalImportError else {
                    return XCTFail("expected a malformed file for an empty \(field), got \(error)")
                }
                XCTAssertTrue(reason.contains("$.saved_meals[1].items[0].\(field) is empty"), reason)
            }
            XCTAssertEqual(try journal.activeIntakes(), [], field)
            XCTAssertTrue(try favoritesStore.list().isEmpty, field)
            XCTAssertEqual(savedMeals.meals, [], field)
        }
    }

    /// Saved meals, their items and the items' components count toward the import's element ceiling, as
    /// favorites and their components do.
    func testSavedMealsCountTowardTheImportCeiling() throws {
        let full = try savedMealsExport()
        var root = try fields(full)
        root["saved_meals"] = [[String: Any]]()
        let without = try JSONSerialization.data(withJSONObject: root)
        // The smallest ceiling the file without saved meals passes.
        var ceiling = 0
        while (try? JournalImportLimits(maxImportBytes: 1 << 24, maxAggregateElements: ceiling).validate(without)) == nil {
            ceiling += 1
            guard ceiling < 10_000 else { return XCTFail("no ceiling found") }
        }
        XCTAssertThrowsError(
            try JournalImportLimits(maxImportBytes: 1 << 24, maxAggregateElements: ceiling).validate(full)) {
            XCTAssertEqual($0 as? JournalImportError, .tooLarge)
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
            XCTAssertEqual($0 as? JournalImportError, .savedMealsNotEmpty)
        }
        XCTAssertEqual(try journal.activeIntakes(), [])
        XCTAssertEqual(savedMeals.meals.map(\.id), ["mine"])
    }

    /// A version 4 file states the whole saved meals list, so even one with none is not restored over a phone
    /// that keeps some: what the phone keeps would otherwise stay mixed into the restored data.
    func testAVersion4FileWithNoSavedMealsIsRefusedOverAPhoneThatKeepsSome() throws {
        let directory = try self.directory()
        let data = try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: try filledStore(directory), savedMeals: MemorySavedMeals(), goals: InMemoryGoalStore(), appVersion: appVersion,
                exportedAt: exportedAt))
        let target = try self.directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals([JournalSavedMeal(id: "mine", name: "Mine", meal: nil, items: [template("x", name: "X")])])
        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: nil, savedMeals: savedMeals)) {
            XCTAssertEqual($0 as? JournalImportError, .savedMealsNotEmpty)
        }
        XCTAssertEqual(try journal.activeIntakes(), [])
        XCTAssertEqual(savedMeals.meals.map(\.id), ["mine"])
    }

    /// A meal saved in another window after the import checked the list is not overwritten: the store refuses
    /// the write, and the journal is undone.
    func testAMealSavedMeanwhileIsNotOverwritten() throws {
        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        let mine = JournalSavedMeal(id: "mine", name: "Mine", meal: nil, items: [template("x", name: "X")])
        savedMeals.beforeRestore = { store in if store.meals.isEmpty { store.meals = [mine] } }
        XCTAssertThrowsError(try JournalImporter.importExport(
            try savedMealsExport(), into: journal, favorites: try favorites(target), savedMeals: savedMeals)) {
            XCTAssertEqual($0 as? JournalImportError, .savedMealsNotEmpty)
        }
        XCTAssertEqual(savedMeals.meals, [mine])
        XCTAssertEqual(try journal.activeIntakes(), [])
    }

    /// Undoing the saved meals after a failed favorites write leaves a list someone changed meanwhile alone.
    /// The journal stays too, since those meals still name its products, and the restore is reported as partial.
    func testUndoLeavesAListChangedMeanwhile() throws {
        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        let favorites = FailingFavorites()
        favorites.beforeFailing = { savedMeals.meals.removeLast() }
        XCTAssertThrowsError(try JournalImporter.importExport(
            try savedMealsExport(), into: journal, favorites: favorites, savedMeals: savedMeals)) {
            XCTAssertEqual($0 as? JournalImportError, .partialRestore(retainedIntakes: 2, retainedTombstones: 1))
        }
        XCTAssertEqual(savedMeals.meals.map(\.id), ["meal-2"], "the changed list is left as it is")
        XCTAssertEqual(try journal.activeIntakes().count, 2, "the journal keeps the products the meals name")
        XCTAssertNotNil(try journal.product(snapshotID: "snap-oats-1"))
    }

    /// A file with no entries at all writes nothing to the journal, so a stop after its saved meals leaves an
    /// empty journal; the flag naming the file is what lets the same file finish.
    func testAStopInAFileWithNoEntriesIsFinished() throws {
        let source = try directory()
        let favoritesSource = try favorites(source)
        try favoritesSource.add(template("fav-tea-1", name: "Sample tea"))
        let lunch = JournalSavedMeal(id: "meal-2", name: "Lunch box", meal: nil, items: [template("item-3", name: "Sample apple")])
        let data = try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: try store(source), favorites: favoritesSource, savedMeals: MemorySavedMeals([lunch]),
                goals: InMemoryGoalStore(), appVersion: appVersion, exportedAt: exportedAt))
        let digest = JournalImporter.fileDigest(data)
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let savedMeals = MemorySavedMeals()
        try journal.markRestoreInProgress(fileDigest: digest)
        try savedMeals.restoreJournalSavedMeals([lunch], receipt: digest)

        _ = try JournalImporter.importExport(data, into: journal, favorites: favoritesStore, savedMeals: savedMeals)
        XCTAssertEqual(try favoritesStore.list().map(\.id), ["fav-tea-1"])
        XCTAssertEqual(savedMeals.meals, [lunch])
        XCTAssertNil(try journal.restoreInProgressDigest())
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
                store: try filledStore(directory), savedMeals: MemorySavedMeals(sampleMeals()), goals: InMemoryGoalStore(), appVersion: appVersion,
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
            XCTAssertEqual($0 as? JournalImportError, .alreadyRestored)
        }
        XCTAssertEqual(savedMeals.meals, [])
    }

    /// A saved meal item keeps its water share through the export and the restore, as a favorite does.
    func testASavedMealItemKeepsItsWaterShareThroughExportAndImport() throws {
        let shared = JournalSavedMeal(
            id: "meal-share", name: "Soda lunch", meal: nil,
            items: [FavoriteTemplate(
                id: "item-soda", displayName: "7up", category: "other",
                components: [FavoriteComponent(
                    componentID: "soda", name: "7up", amountText: "200", unitSymbol: "mL",
                    hydrationPercentText: "95")])])
        let data = try JournalExporter.encode(
            try JournalExporter.makeExport(
                store: try filledStore(try directory()), favorites: nil,
                savedMeals: MemorySavedMeals([shared]), goals: InMemoryGoalStore(), appVersion: appVersion, exportedAt: exportedAt))
        let restoreDirectory = try directory()
        let target = try store(restoreDirectory)
        let savedMeals = MemorySavedMeals()

        _ = try JournalImporter.importExport(
            data, into: target, favorites: try favorites(restoreDirectory), savedMeals: savedMeals)

        XCTAssertEqual(
            savedMeals.meals.first?.items.first?.components.first?.hydrationPercentText, "95")
    }

    /// A resume whose goal read throws, with a saved meal in the file. Reading the goals must fail before the saved
    /// meals are written, so the restore writes no meal and reports the failure. The old reader treated the failed
    /// read as pending and wrote the meals first, which is what this test catches.
    func testAGoalReadThatFailsStopsAResumeBeforeItWritesSavedMeals() throws {
        let directory = try self.directory()
        let meals = [JournalSavedMeal(id: "meal-x", name: "Lunch box", meal: nil, items: [template("item-x", name: "Sample apple")])]
        let encoded = try JournalExporter.encode(try JournalExporter.makeExport(
            store: try store(directory), savedMeals: MemorySavedMeals(meals), goals: InMemoryGoalStore(), appVersion: appVersion, exportedAt: exportedAt))
        var root = try fields(encoded)
        root["goals"] = [["nutrient": "energy", "target": "2000", "unit": "kcal"]]
        let data = try JSONSerialization.data(withJSONObject: root)

        let journal = try store(directory)
        try journal.markRestoreInProgress(fileDigest: JournalImporter.fileDigest(data))
        let goalStore = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        addTeardownBlock { goalStore.close() }
        let goals = ScriptedGoalStore(base: goalStore) { _, _ in }
        goals.failsRead = true
        let savedMeals = MemorySavedMeals()

        XCTAssertThrowsError(try JournalImporter.importExport(
            data, into: journal, favorites: nil, savedMeals: savedMeals, goals: goals))
        XCTAssertTrue(savedMeals.meals.isEmpty, "no saved meal is written before the goal read fails")
        XCTAssertNil(savedMeals.receipt)
    }

    /// A saved-meal undo that fails keeps the restore flag, so a re-import of the same file resumes with the right counts.
    /// Fails when the flag is cleared on that path, since the re-import is then refused as not empty.
    func testAFailedSavedMealUndoKeepsTheFlagSoAReimportResumes() throws {
        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        savedMeals.failClear = true
        let data = try savedMealsExport()
        XCTAssertThrowsError(try JournalImporter.importExport(
            data, into: journal, favorites: FailingFavorites(), savedMeals: savedMeals)) {
            XCTAssertEqual($0 as? JournalImportError, .partialRestore(retainedIntakes: 2, retainedTombstones: 1))
        }
        XCTAssertNotNil(try journal.restoreInProgressDigest(), "a failed saved-meal undo keeps the flag for a resume")

        savedMeals.failClear = false
        var summary: JournalImportSummary?
        XCTAssertNoThrow(summary = try JournalImporter.importExport(
            data, into: journal, favorites: try favorites(target), savedMeals: savedMeals))
        XCTAssertEqual(summary?.savedMeals, 2)
        XCTAssertEqual(savedMeals.meals.map(\.id), ["meal-2", "meal-1"], "no saved meal is duplicated")
        XCTAssertEqual(try journal.activeIntakes().count, summary?.intakes, "no entry is duplicated")
        XCTAssertNil(try journal.restoreInProgressDigest(), "the finished resume clears its flag")
    }
    /// A saved-meal undo that fails stops the rollback before the journal and the goals are touched, so the goal
    /// this restore wrote and the journal it filled stay for the resume, and the flag keeps the resume possible.
    /// Fails when goals are removed ahead of the saved-meal step, since the goal would then be gone for good.
    func testAFailedSavedMealUndoLeavesGoalsAndJournalForTheResume() throws {
        let target = try directory()
        let journal = try store(target)
        let savedMeals = MemorySavedMeals()
        savedMeals.failClear = true
        var root = try fields(try savedMealsExport())
        root["goals"] = [["nutrient": "energy", "target": "2000", "unit": "kcal"]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let goals = try SwiftDataGoalStore(url: target.appendingPathComponent("goals.store"))
        addTeardownBlock { goals.close() }

        XCTAssertThrowsError(try JournalImporter.importExport(
            data, into: journal, favorites: FailingFavorites(), savedMeals: savedMeals, goals: goals)) {
            XCTAssertEqual($0 as? JournalImportError, .partialRestore(retainedIntakes: 2, retainedTombstones: 1))
        }
        XCTAssertEqual(try goals.goal(for: "energy")?.target, 2000, "the goal stays for the resume")
        XCTAssertFalse(try journal.activeIntakes().isEmpty, "the journal is not undone while a saved meal is left")
        XCTAssertNotNil(try journal.restoreInProgressDigest(), "the flag is kept for the resume")

        savedMeals.failClear = false
        var summary: JournalImportSummary?
        XCTAssertNoThrow(summary = try JournalImporter.importExport(
            data, into: journal, favorites: try favorites(target), savedMeals: savedMeals, goals: goals))
        XCTAssertEqual(summary?.savedMeals, 2)
        XCTAssertEqual(try goals.goal(for: "energy")?.target, 2000, "the resume keeps the goal once")
        XCTAssertEqual(try journal.activeIntakes().count, summary?.intakes, "no entry is duplicated")
        XCTAssertNil(try journal.restoreInProgressDigest(), "the finished resume clears its flag")
    }
}
