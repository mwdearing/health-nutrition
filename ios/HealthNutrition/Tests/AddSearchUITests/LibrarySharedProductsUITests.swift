import XCTest

final class LibrarySharedProductsUITests: XCTestCase {
    /// A Library search with no match offers Find shared products, and the button opens product search.
    /// The product search screen is matched by its field identifier, not by any text that could repeat.
    func testSearchWithNoMatchOffersFindSharedProducts() throws {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), "no Library tab")
        libraryTab.tap()

        let search = app.textFields["Search on this phone"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Library search field is not on screen")
        search.tap()
        search.typeText("zzqxnomatch")

        let findShared = app.buttons["Find shared products"]
        XCTAssertTrue(findShared.waitForExistence(timeout: 10),
                      "a search with no match does not offer Find shared products")
        findShared.tap()

        let productField = app.textFields["sharedProductSearchField"]
        XCTAssertTrue(productField.waitForExistence(timeout: 10),
                      "Find shared products did not open product search")
    }
}
