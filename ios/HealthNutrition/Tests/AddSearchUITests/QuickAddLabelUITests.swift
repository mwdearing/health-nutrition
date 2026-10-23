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
        // Add UI tests do. (isHittable is an element property, not a query predicate.)
        let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !addCandidates.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let addButton = addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(addButton, "no hittable Add button on the Today screen")
        addButton?.tap()

        let amountsOnly = app.buttons["Amounts only"]
        XCTAssertTrue(amountsOnly.waitForExistence(timeout: 10), "the Amounts only quick action is not on the Add screen")
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
