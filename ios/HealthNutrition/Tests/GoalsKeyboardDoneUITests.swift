import XCTest

/// A goal target is a decimal field. Its keyboard has a Done key, so the person can dismiss it without a return key.
/// The test first checks the software keyboard is on screen, so a simulator with a hardware keyboard fails here,
/// not on the Done key.
final class GoalsKeyboardDoneUITests: XCTestCase {
    func testGoalTargetKeyboardHasADoneKey() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let edit = app.buttons["Edit goals"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "no Edit goals button on Today")
        edit.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no goal target field on the Daily goals screen")
        field.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "no software keyboard on screen (is a hardware keyboard attached to the simulator?)")
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5),
                      "the goal target keyboard has no Done key")
    }
}
