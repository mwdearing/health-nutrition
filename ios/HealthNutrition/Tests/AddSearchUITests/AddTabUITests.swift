import XCTest

/// The Add tab opens Add from any tab, and the tab that was showing stays selected when Add closes.
final class AddTabUITests: XCTestCase {
    func testAddOpensFromLibraryAndLibraryStaysSelected() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30), "no Library tab")
        library.tap()
        XCTAssertTrue(pollUntil(timeout: 10, { library.isSelected }), "the Library tab did not become selected")

        let add = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        func hittableAdd() -> XCUIElement? { add.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) }
        XCTAssertTrue(pollUntil(timeout: 15, { hittableAdd() != nil }), "no hittable Add tab on the Library screen")
        hittableAdd()?.tap()

        let amountsOnly = app.buttons["Amounts only"]
        XCTAssertTrue(amountsOnly.waitForExistence(timeout: 20), "the Add tab did not open Add")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Add has no Cancel button")
        cancel.tap()
        XCTAssertTrue(amountsOnly.waitForNonExistence(timeout: 15), "Add did not close")

        XCTAssertTrue(pollUntil(timeout: 10, { library.isSelected }), "closing Add did not return to the Library tab")
        XCTAssertTrue(app.textFields["Search on this device"].waitForExistence(timeout: 10), "the Library screen is not showing")
    }

    func testTheTabBarShowsTheFourTabsInOrder() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let names = ["Today", "Diary", "Library", "Trends"]
        for name in names {
            XCTAssertTrue(app.tabBars.buttons[name].waitForExistence(timeout: 30), "no \(name) tab")
        }
        let xs = names.map { app.tabBars.buttons[$0].frame.midX }
        XCTAssertEqual(xs, xs.sorted(), "the tabs are not in the order Today, Diary, Library, Trends")
    }
}
