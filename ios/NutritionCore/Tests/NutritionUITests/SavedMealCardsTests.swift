import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Library's saved meals row: what each card says, which one is the highlight, when the row shows, and that
/// a card logs through the saved meals model with Undo. Synthetic names only.
@MainActor
final class SavedMealCardsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ name: String) -> FavoriteTemplate {
        FavoriteTemplate(
            id: UUID().uuidString.lowercased(), displayName: name, category: "food",
            components: [FavoriteComponent(componentID: name.lowercased(), name: name, amountText: "40", unitSymbol: "g")])
    }

    private func meal(_ name: String, items: Int, label: MealLabel? = .breakfast) -> SavedMeal {
        SavedMeal(id: name.lowercased(), name: name, meal: label, items: (1...items).map { item("Food \($0)") })
    }

    func testACardCountsItsItemsAndCalories() {
        let cards = SavedMealCards.make(
            [meal("Usual breakfast", items: 3), meal("Post-run shake", items: 1), meal("Plain toast", items: 2)],
            calories: { $0.name == "Plain toast" ? nil : ($0.items.count == 3 ? 412 : 1) })
        XCTAssertEqual(cards.map(\.name), ["Usual breakfast", "Post-run shake", "Plain toast"])
        XCTAssertEqual(cards[0].detail, "3 items · 412 calories")
        // One item and one calorie are singular.
        XCTAssertEqual(cards[1].detail, "1 item · 1 calorie")
        // An unknown total is left out, never shown as zero.
        XCTAssertEqual(cards[2].detail, "2 items")
    }

    func testTheFirstCardIsTheHighlight() {
        let cards = SavedMealCards.make(
            [meal("Usual breakfast", items: 2), meal("Post-run shake", items: 1)], calories: { _ in 100 })
        XCTAssertEqual(cards.map(\.isHighlight), [true, false])
    }

    func testNoRowWithoutSavedMeals() {
        XCTAssertTrue(SavedMealCards.make([], calories: { _ in nil }).isEmpty)
        XCTAssertFalse(SavedMealCards.isShown(inPickMode: false, mealCount: 0, searchText: ""))
        XCTAssertTrue(SavedMealCards.isShown(inPickMode: false, mealCount: 2, searchText: ""))
        XCTAssertTrue(SavedMealCards.isShown(inPickMode: false, mealCount: 2, searchText: "   "))
        XCTAssertFalse(SavedMealCards.isShown(inPickMode: false, mealCount: 2, searchText: "oats"))
        XCTAssertFalse(SavedMealCards.isShown(inPickMode: true, mealCount: 2, searchText: ""))
    }

    /// A save shows on the cards at once: the cards follow the value the saved meals model just published, not the
    /// one it held before.
    func testSavingAMealUpdatesTheCardsImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let journal = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let suite = "saved-meal-cards-sink-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let entry = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC", meal: "breakfast")
        try journal.create(
            entry, components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: nil, now: now)
        let model = SavedMealsModel(store: UserDefaultsSavedMealStore(defaults: defaults), journal: journal, timeZoneIdentifier: "UTC")
        let library = LibraryViewModel(store: journal)
        library.savedMeals = model
        XCTAssertTrue(library.savedMealCards.isEmpty)

        XCTAssertTrue(model.save(name: "Usual breakfast", meal: .breakfast, intakes: [entry]))
        XCTAssertEqual(library.savedMealCards.map(\.name), ["Usual breakfast"])
        XCTAssertTrue(model.save(name: "Post-run shake", meal: nil, intakes: [entry]))
        XCTAssertEqual(library.savedMealCards.map(\.name), ["Usual breakfast", "Post-run shake"])
    }

    func testLoggingFromACardLogsEveryItemAndOffersUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let journal = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let suite = "saved-meal-cards-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let book = SavedMealBook(store: UserDefaultsSavedMealStore(defaults: defaults))
        let templates = ["Oats", "Milk"].map {
            RepeatTemplate(
                displayName: $0, category: "food", meal: nil,
                components: [IntakeComponent(componentID: $0.lowercased(), name: $0, amount: 40, unit: .g)])
        }
        let saved = try book.add(name: "Usual breakfast", meal: .breakfast, templates: templates)
        let model = SavedMealsModel(
            store: UserDefaultsSavedMealStore(defaults: defaults), journal: journal, timeZoneIdentifier: "UTC")
        model.load()

        // The card's button asks which meal, offering the saved meal's own first, then logs through the model.
        XCTAssertEqual(SavedMealsModel.mealChoices(for: saved).first, .some(.breakfast))
        XCTAssertTrue(model.log(saved, as: .lunch, now: now))
        XCTAssertEqual(try journal.activeIntakes().count, 2)
        XCTAssertEqual(try journal.activeIntakes().map(\.meal), ["lunch", "lunch"])
        let token = try XCTUnwrap(model.undoToken)
        XCTAssertEqual(token.message, "Logged Usual breakfast.")

        XCTAssertTrue(model.undo(now: now))
        XCTAssertEqual(try journal.activeIntakes().count, 0)
        XCTAssertNil(model.undoToken)
    }
}
