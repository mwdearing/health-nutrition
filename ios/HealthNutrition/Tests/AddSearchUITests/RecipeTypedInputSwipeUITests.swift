import XCTest

/// A typed new recipe must not be lost to an edge swipe-back. Route: Library tab, "Open recipes",
/// "New recipe" (RootView.recipesSheet pushes the editor). The test types a title, drags from the left
/// screen edge, then checks the discard question is up or the typed title is still on screen.
final class RecipeTypedInputSwipeUITests: XCTestCase {
    func testEdgeSwipeBackKeepsTypedRecipeOrAsksFirst() throws {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "no Library tab")
        library.tap()

        let openRecipes = app.buttons["Open recipes"]
        XCTAssertTrue(openRecipes.waitForExistence(timeout: 10), "Library has no Open recipes control")
        openRecipes.tap()

        let newRecipe = app.buttons["New recipe"]
        XCTAssertTrue(newRecipe.waitForExistence(timeout: 10), "the recipes list has no New recipe control")
        newRecipe.tap()

        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the recipe editor has no text field")
        title.tap()
        title.typeText("Pancakes")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        let askedFirst = app.buttons["Discard"].waitForExistence(timeout: 3)
        let stillThere = app.textFields.firstMatch.value as? String == "Pancakes"
        XCTAssertTrue(askedFirst || stillThere,
                      "the edge swipe left the recipe editor and lost the typed title without asking")
    }
}
