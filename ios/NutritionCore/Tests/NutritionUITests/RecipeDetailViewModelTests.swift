import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class RecipeDetailViewModelTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"

    private func makeJournal() throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: try uiTempURL(self, "journal.store"))
    }

    func testPerServingRowsAndProvenance() throws {
        let model = RecipeDetailViewModel(version: uiSampleVersion(), journal: try makeJournal())
        XCTAssertEqual(model.rows.first(where: { $0.id == "energy" })?.text, "215 kcal")
        XCTAssertEqual(model.provenanceText, "Calculated from version 1")
    }

    func testUnknownShownAsUnknownNotZero() throws {
        let version = uiSampleVersion(perUnitB: ["energy": .known(8, .kcal)])
        let model = RecipeDetailViewModel(version: version, journal: try makeJournal())
        let protein = model.rows.first(where: { $0.id == "protein" })
        XCTAssertEqual(protein?.text, "unknown")
        XCTAssertEqual(model.coverageTexts, ["1 of 2 ingredients lack protein"])
    }

    func testPortionChangeRecalculatesAndBadPortionShowsError() throws {
        let model = RecipeDetailViewModel(version: uiSampleVersion(), journal: try makeJournal())
        model.portionText = "2"
        XCTAssertEqual(model.rows.first(where: { $0.id == "energy" })?.text, "430 kcal")
        model.portionText = "0"
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLogPortionWritesOneIntake() throws {
        let journal = try makeJournal()
        let model = RecipeDetailViewModel(
            version: uiSampleVersion(), journal: journal, timeZoneIdentifier: "UTC", makeID: { self.intakeID })
        XCTAssertTrue(model.logPortion(now: when))
        XCTAssertEqual(try journal.activeIntakes().count, 1)
        XCTAssertEqual(try journal.revisions(of: intakeID)[0].productSnapshotID, "recipe:recipe-1:v1")
    }

    /// A logged recipe is one component named after the recipe, so Journal and Library name the recipe
    /// the user chose rather than a list of nutrients.
    func testLoggedRecipeIsNamedAfterTheRecipeInJournalAndRecents() throws {
        let journal = try makeJournal()
        let model = RecipeDetailViewModel(
            version: uiSampleVersion(), journal: journal, timeZoneIdentifier: "UTC", makeID: { self.intakeID })
        XCTAssertTrue(model.logPortion(now: when))

        let journalModel = JournalViewModel(store: journal, timeZoneIdentifier: "UTC")
        journalModel.load(now: when)
        XCTAssertEqual(journalModel.sections.flatMap(\.rows).map(\.title), ["Oat bake"])

        let recents = try RecentItemsProvider(store: journal).recents()
        XCTAssertEqual(recents.map { $0.template.displayName }, ["Oat bake"])
    }

    /// A recipe whose nutrient is a known zero still logs an entry whose amounts can be read back, so
    /// the entry editor, repeat and favorites all keep working.
    func testEntryFromAZeroNutrientRecipeCanBeSavedRepeatedAndFavorited() throws {
        let journal = try makeJournal()
        let favorites = try SwiftDataFavoritesStore(url: try uiTempURL(self, "favorites.store"))
        let version = RecipeVersion(
            recipeID: "recipe-zero", number: 1, title: "Salt free bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                    perUnit: ["sodium": .known(0, .mg), "protein": .known(Decimal(13), .g)])
            ],
            yield: .servings(4), createdAt: when)
        let model = RecipeDetailViewModel(
            version: version, journal: journal, timeZoneIdentifier: "UTC", makeID: { self.intakeID })
        XCTAssertTrue(model.logPortion(now: when))

        let entry = EntryDetailViewModel(store: journal, intakeID: intakeID, timeZoneIdentifier: "UTC")
        entry.load(now: when)
        XCTAssertEqual(entry.components.count, 1)
        XCTAssertTrue(entry.saveDrafts(now: when), "\(entry.fieldErrors)")

        let library = LibraryViewModel(store: journal, favorites: favorites, timeZoneIdentifier: "UTC")
        library.load()
        let item = try XCTUnwrap(library.sections.flatMap(\.items).first)
        XCTAssertEqual(item.title, "Salt free bake")
        library.addFavorite(item)
        XCTAssertNil(library.errorMessage)
        XCTAssertNotNil(library.select(item, now: when))
    }

    func testCoverageLineTextHelper() {
        let line = RecipeCoverage(nutrientID: "protein", lacking: 1, total: 3)
        XCTAssertEqual(line.text(nutrientName: "protein"), "1 of 3 ingredients lack protein")
    }
}
