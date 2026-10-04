import Combine
import Foundation
import NutritionDomain
import NutritionJournal
import XCTest

@testable import HealthNutrition

/// The recipe sheet's navigation state on its own.
///
/// The erase on the Connections and privacy screen has to close the sheet and drop every route in it:
/// a detail or an editor screen holds its own copy of a recipe, so an erased recipe would otherwise
/// stay on screen and could still be logged. That reaction used to be view state inside `RootView`,
/// where nothing could reach it without a UI test, so it lives in `RecipeNavigation` instead.
@MainActor
final class RecipeNavigationTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleVersion() -> RecipeVersion {
        RecipeVersion(
            recipeID: "recipe-oats", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour",
                    quantity: Quantity(value: Decimal(string: "200")!, unit: .g),
                    perUnit: ["energy": .known(Decimal(string: "3.6")!, .kcal)])
            ],
            yield: .servings(4), createdAt: when)
    }

    /// Nothing is open before anything is opened.
    func testANewNavigationHasNoSheetAndNoRoutes() {
        let navigation = RecipeNavigation()

        XCTAssertFalse(navigation.showingRecipes)
        XCTAssertTrue(navigation.path.isEmpty)
    }

    /// Opening presents the sheet from a clean stack, so a route left from earlier is not behind it.
    func testOpeningPresentsTheSheetFromACleanStack() {
        let navigation = RecipeNavigation()
        navigation.path = [.editor(nil)]

        navigation.open()

        XCTAssertTrue(navigation.showingRecipes)
        XCTAssertTrue(navigation.path.isEmpty)
    }

    /// The erase reaction: the sheet closes and every route goes, so no screen is left holding a copy
    /// of a recipe that no longer exists.
    func testResetClosesTheSheetAndClearsThePath() {
        let navigation = RecipeNavigation()
        navigation.open()
        let version = sampleVersion()
        navigation.path = [.detail(version), .editor(version)]

        navigation.reset()

        XCTAssertFalse(navigation.showingRecipes)
        XCTAssertTrue(navigation.path.isEmpty)
    }

    /// Both properties are published, so the sheet and the stack read them as bindings and the erase
    /// reaches the screen. Without the publishing the array would be emptied and the route would stay
    /// on screen.
    func testResetPublishesBothPropertiesSoTheScreenFollows() {
        let navigation = RecipeNavigation()
        navigation.open()
        navigation.path = [.detail(sampleVersion())]
        var publishedPaths: [Int] = []
        var publishedPresentation: [Bool] = []
        let paths = navigation.$path.sink { publishedPaths.append($0.count) }
        let presentation = navigation.$showingRecipes.sink { publishedPresentation.append($0) }
        defer {
            paths.cancel()
            presentation.cancel()
        }

        navigation.reset()

        XCTAssertEqual(publishedPaths.last, 0)
        XCTAssertEqual(publishedPresentation.last, false)
    }
}
