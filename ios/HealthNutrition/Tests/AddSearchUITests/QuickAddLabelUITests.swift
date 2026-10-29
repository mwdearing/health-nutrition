import XCTest

/// The amounts-only form's name field reads its visible title, so VoiceOver and UI tests name it while typing.
final class QuickAddLabelUITests: XCTestCase {
    func testAmountsOnlyNameFieldReadsItsTitle() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        // The shared opener waits for a hittable Add button and retries a tap that landed while Today settled.
        let amountsOnly = app.buttons["Amounts only"]
        XCTAssertTrue(
            openAddScreen(in: app, until: amountsOnly), "the Amounts only quick action is not on the Add screen")
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

