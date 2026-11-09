import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Saved meal quick action on Add: when the tile shows, which meal a tap logs with, and when it asks.
/// Synthetic names only.
@MainActor
final class AddSavedMealsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeSavedMeals(_ journal: SwiftDataJournalStore) throws -> (SavedMealsModel, SavedMeal) {
        let suite = "add-saved-meals-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now.addingTimeInterval(-600),
            timeZoneIdentifier: "UTC", meal: "breakfast")
        try journal.create(
            intake, components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: nil, now: now.addingTimeInterval(-600))
        let model = SavedMealsModel(
            store: UserDefaultsSavedMealStore(defaults: defaults), journal: journal, timeZoneIdentifier: "UTC")
        XCTAssertTrue(model.save(name: "Usual breakfast", meal: .breakfast, intakes: [intake]))
        return (model, try XCTUnwrap(model.meals.first))
    }

    func testASavedMealLogsWithAddsMealChoice() throws {
        let journal = try makeJournal()
        let (savedMeals, saved) = try makeSavedMeals(journal)
        let model = AddSavedMealsViewModel(savedMeals: savedMeals, meal: .dinner, now: { self.now })

        XCTAssertTrue(model.choose(saved))
        XCTAssertNil(model.mealToAsk)
        XCTAssertEqual(try journal.activeIntakes().filter { $0.occurredAt == now }.map(\.meal), ["dinner"])
        XCTAssertNotNil(savedMeals.undoToken)
    }

    func testWithNoMealChosenTheMealIsAsked() throws {
        let journal = try makeJournal()
        let (savedMeals, saved) = try makeSavedMeals(journal)
        let model = AddSavedMealsViewModel(savedMeals: savedMeals, meal: nil, now: { self.now })

        XCTAssertFalse(model.choose(saved))
        XCTAssertEqual(model.mealToAsk, saved)
        XCTAssertEqual(model.mealChoices, SavedMealsModel.mealChoices(for: saved))
        XCTAssertEqual(try journal.activeIntakes().filter { $0.occurredAt == now }, [])

        XCTAssertTrue(model.log(saved, as: .snack))
        XCTAssertNil(model.mealToAsk)
        XCTAssertEqual(try journal.activeIntakes().filter { $0.occurredAt == now }.map(\.meal), ["snack"])
    }

    func testNoSavedMealsMeansNoTile() {
        XCTAssertFalse(AddSavedMealsViewModel.showsTile(savedMealCount: 0))
        XCTAssertTrue(AddSavedMealsViewModel.showsTile(savedMealCount: 1))
    }
}
