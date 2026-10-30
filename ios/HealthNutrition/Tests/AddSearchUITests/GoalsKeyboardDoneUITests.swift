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
        XCTAssertTrue(edit.waitForExistence(timeout: 15), "no Edit goals button on Today")
        edit.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no goal target field on the Daily goals screen")
        // Settings has its own Done button, so the keyboard's is counted on top of the ones already on screen.
        let doneBefore = app.buttons.matching(identifier: "Done").count
        field.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "no software keyboard on screen (is a hardware keyboard attached to the simulator?)")
        let keyboardDone = NSPredicate { _, _ in app.buttons.matching(identifier: "Done").count > doneBefore }
        let appeared = expectation(for: keyboardDone, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 5), .completed,
                       "the goal target keyboard has no Done key\n\(app.debugDescription)")
    }
}
