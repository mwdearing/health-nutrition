import XCTest

final class AddSearchRowUITests: XCTestCase {
    /// The search row sits at the top of Add. It must be on screen and hittable, and a tap must open
    /// product search with the field focused, so typing starts at once.
    func testSearchRowIsOnAddAndTapFocusesTheSearchField() throws {
        let app = XCUIApplication()
        app.launch()

        let addButton = app.buttons["Add food, drink, or supplement"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "the Add button is not on the Today screen")
        addButton.tap()

        let row = app.buttons["Search foods, brands, drinks"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the search row is not on the Add screen")
        XCTAssertTrue(row.isHittable, "the search row is on screen but cannot be tapped")
        row.tap()

        let field = app.textFields["Search foods and products"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "product search did not open")
        // The field takes focus after a short delay, so poll for it rather than checking once.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focused, object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed,
                       "the search field did not take focus after the row was tapped")
    }
}
