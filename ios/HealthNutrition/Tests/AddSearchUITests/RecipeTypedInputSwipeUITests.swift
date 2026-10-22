import XCTest

/// A typed new recipe must not be lost to an edge swipe-back. Route: Library tab, "Open recipes",
/// "New recipe" (RootView.recipesSheet pushes the editor). The test types a title, drags from the left
/// screen edge, then checks the discard question is up or the typed title is still on screen.
final class RecipeTypedInputSwipeUITests: XCTestCase {
    /// Ends the app after each test so a leftover app cannot carry its typed state into the next run.
    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        try super.tearDownWithError()
    }

    func testEdgeSwipeBackKeepsTypedRecipeOrAsksFirst() throws {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "no Library tab")
        library.tap()

        // "Open recipes" only shows inside the Recipes segment of Library, so select that segment first.
        let segment = app.segmentedControls.buttons["Recipes"].firstMatch
        let recipesTab = segment.waitForExistence(timeout: 5) ? segment : app.buttons["Recipes"].firstMatch
        XCTAssertTrue(recipesTab.waitForExistence(timeout: 10), "Library has no Recipes segment")
        recipesTab.tap()

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

        assertOneLeadingControl(app, bar: "Recipe")
        // Put the keyboard away first: a tap on the form background dismisses it, and the edge drag only pops
        // when no keyboard is up. Return is the fallback for a text keyboard that a background tap leaves up.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        if app.keyboards.buttons["Return"].firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tap() }
        // The swipe must not run against a keyboard: wait for it to be gone, and fail the test if it is not.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "the keyboard did not go away before the swipe")
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        let askedFirst = app.buttons["Discard"].waitForExistence(timeout: 3)
        let stillThere = app.textFields.firstMatch.value as? String == "Pancakes"
        XCTAssertTrue(askedFirst || stillThere,
                      "the edge swipe left the recipe editor and lost the typed title without asking")
    }
}

/// Once a form is pushed, its own navigation bar shows exactly one leading control, Back or Cancel.
private func assertOneLeadingControl(_ app: XCUIApplication, bar: String, file: StaticString = #filePath, line: UInt = #line) {
    let navBar = app.navigationBars[bar]
    XCTAssertTrue(navBar.waitForExistence(timeout: 10), "\(bar) bar is missing", file: file, line: line)
    let leading = navBar.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Cancel"))
    XCTAssertEqual(leading.count, 1, "\(bar) shows \(leading.count) leading controls, expected one", file: file, line: line)
}
