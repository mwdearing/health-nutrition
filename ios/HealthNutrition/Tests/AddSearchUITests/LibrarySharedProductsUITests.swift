import XCTest

final class LibrarySharedProductsUITests: XCTestCase {
    /// A Library search with no match offers Find shared products, and the button opens product search.
    /// The product search screen is matched by its field identifier, not by any text that could repeat.
    func testSearchWithNoMatchOffersFindSharedProducts() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), "no Library tab")
        libraryTab.tap()

        let search = app.textFields["Search on this device"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Library search field is not on screen")
        // On a slow runner a tap can land while Library is still settling and leave the field without keyboard
        // focus, and typing then fails. The tap is checked by the field taking focus, with one more tap if it has not.
        func searchHasFocus() -> Bool { (search.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        search.tap()
        if !waitUntil(timeout: 10, searchHasFocus) { search.tap() }
        XCTAssertTrue(waitUntil(timeout: 10, searchHasFocus), "the Library search field did not take keyboard focus")
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

/// Polls `condition` until it holds or `timeout` seconds pass; true when it held.
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
}
