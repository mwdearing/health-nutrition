import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The app's saved meals store as the journal export and restore see it, and the import's one-line summary.
///
/// Synthetic names and ids only.
@MainActor
final class SavedMealsBackupTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "saved-meals-backup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func meal(_ id: String, _ name: String) -> JournalSavedMeal {
        JournalSavedMeal(
            id: id, name: name, meal: .lunch,
            items: [FavoriteTemplate(
                id: "\(id)-item", displayName: "Sample apple", category: "food",
                components: [FavoriteComponent(componentID: "apple", name: "Sample apple", amountText: "150", unitSymbol: "g")])])
    }

    func testARestoredListReadsBackInItsOrderWithItsReceipt() throws {
        let store = UserDefaultsSavedMealStore(defaults: makeDefaults())
        let meals = [meal("meal-2", "Lunch box"), meal("meal-1", "Usual lunch")]

        try store.restoreJournalSavedMeals(meals, receipt: "digest-1")
        XCTAssertEqual(try store.journalSavedMeals(), meals)
        XCTAssertEqual(try store.meals().map(\.name), ["Lunch box", "Usual lunch"])
        XCTAssertTrue(try store.hasSavedMealsRestoreReceipt("digest-1"))
        XCTAssertFalse(try store.hasSavedMealsRestoreReceipt("digest-2"))

        // Another file's receipt is not forgotten in its place.
        try store.removeSavedMealsRestoreReceipt("digest-2")
        XCTAssertTrue(try store.hasSavedMealsRestoreReceipt("digest-1"))
        try store.removeSavedMealsRestoreReceipt("digest-1")
        XCTAssertFalse(try store.hasSavedMealsRestoreReceipt("digest-1"))
        XCTAssertEqual(try store.journalSavedMeals(), meals, "forgetting the receipt keeps the list")
    }

    func testEraseAndAnUndoneRestoreForgetTheListAndTheReceipt() throws {
        let defaults = makeDefaults()
        let store = UserDefaultsSavedMealStore(defaults: defaults)
        try store.restoreJournalSavedMeals([meal("meal-1", "Usual lunch")], receipt: "digest-1")
        // A list changed since the restore is left alone.
        XCTAssertThrowsError(try store.clearRestoredSavedMeals([meal("meal-9", "Something else")])) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertEqual(try store.journalSavedMeals().map(\.id), ["meal-1"])
        try store.clearRestoredSavedMeals([meal("meal-1", "Usual lunch")])
        XCTAssertEqual(try store.journalSavedMeals(), [])
        XCTAssertNil(defaults.object(forKey: UserDefaultsSavedMealStore.restoreReceiptKey))

        try store.restoreJournalSavedMeals([meal("meal-1", "Usual lunch")], receipt: "digest-1")
        try store.eraseAll()
        XCTAssertNil(defaults.object(forKey: UserDefaultsSavedMealStore.key))
        XCTAssertNil(defaults.object(forKey: UserDefaultsSavedMealStore.restoreReceiptKey))
    }

    func testARestoreIsRefusedOverAListHoldingOtherMeals() throws {
        let store = UserDefaultsSavedMealStore(defaults: makeDefaults())
        try SavedMealBook(store: store).add(name: "Mine", meal: nil, templates: [
            RepeatTemplate(
                displayName: "Sample pear", category: "food", meal: nil,
                components: [IntakeComponent(componentID: "pear", name: "Sample pear", amount: 1, unit: .serving)],
                productSnapshotID: nil),
        ])
        XCTAssertThrowsError(try store.restoreJournalSavedMeals([meal("meal-1", "Usual lunch")], receipt: "digest-1")) {
            XCTAssertEqual($0 as? JournalImportError, .notEmpty)
        }
        XCTAssertEqual(try store.meals().map(\.name), ["Mine"])
        XCTAssertFalse(try store.hasSavedMealsRestoreReceipt("digest-1"))
    }

    func testTheBookAndTheImporterKeepTheSameLimits() {
        XCTAssertEqual(SavedMealBook.maximumNameLength, JournalSavedMealLimits.maximumNameLength)
        XCTAssertEqual(SavedMealBook.maximumItems, JournalSavedMealLimits.maximumItems)
        XCTAssertEqual(SavedMealBook.maximumMeals, JournalSavedMealLimits.maximumMeals)
    }

    func testTheImportSummaryCountsSavedMeals() {
        func text(favorites: Int, savedMeals: Int) -> String {
            ConnectionsPrivacyViewModel.importSummaryText(
                JournalImportSummary(
                    intakes: 12, revisions: 14, tombstones: 2, favorites: favorites, products: 3, savedMeals: savedMeals))
        }
        XCTAssertEqual(text(favorites: 3, savedMeals: 2), "Imported 12 entries and 2 deleted, 3 favorites, 2 saved meals.")
        XCTAssertEqual(text(favorites: 3, savedMeals: 1), "Imported 12 entries and 2 deleted, 3 favorites, 1 saved meal.")
        XCTAssertEqual(text(favorites: 3, savedMeals: 0), "Imported 12 entries and 2 deleted, 3 favorites.")
    }
}
