import XCTest

/// The amounts-only form's name field reads its visible title, so VoiceOver and UI tests name it while typing.
final class QuickAddLabelUITests: XCTestCase {
    func testAmountsOnlyNameFieldReadsItsTitle() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        // Two buttons share this label and the first is not hittable, so wait for the hittable one, as the other
        // Add UI tests do. (isHittable is an element property, not a query predicate.) The wait is long because a
        // slow runner can take most of a minute to settle after launch.
        let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        func hittableAdd() -> XCUIElement? {
            addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        }
        XCTAssertTrue(waitUntil(timeout: 30, { hittableAdd() != nil }), "no hittable Add button on the Today screen")

        // A tap that lands while Today is still settling leaves Today on screen, so the tap is checked by the Add
        // screen's Amounts only action appearing, with one more tap on the Add button if it does not.
        let amountsOnly = app.buttons["Amounts only"]
        hittableAdd()?.tap()
        if !amountsOnly.waitForExistence(timeout: 10) { hittableAdd()?.tap() }
        XCTAssertTrue(amountsOnly.waitForExistence(timeout: 20), "the Amounts only quick action is not on the Add screen")
        amountsOnly.tap()

        // Wait for the screen's own navigation bar before querying the field, so the query runs once the
        // Amounts only screen is in the tree. The field's label is matched exactly.
        XCTAssertTrue(app.navigationBars["Amounts only"].waitForExistence(timeout: 10), "the Amounts only screen did not open")

        let name = app.textFields["Name (optional)"]
        if !name.waitForExistence(timeout: 10) {
            XCTFail("the name field does not read its visible title\n\(app.debugDescription)")
        }
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
