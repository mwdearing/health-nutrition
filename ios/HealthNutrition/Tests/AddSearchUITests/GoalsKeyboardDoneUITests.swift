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

        // A goal target, found by its spoken name: other fields on the screen, such as a water container size, are
        // not goal targets.
        let field = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Daily target for")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no goal target field on the Daily goals screen")
        // Settings has its own Done button, so the keyboard's is counted on top of the ones already on screen.
        // SwiftUI gives a Button("Done") the label Done and no identifier, so the buttons are matched by label.
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        let doneBefore = done.count
        field.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "no software keyboard on screen (is a hardware keyboard attached to the simulator?)")
        let keyboardDone = NSPredicate { _, _ in done.count > doneBefore }
        let appeared = expectation(for: keyboardDone, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 5), .completed,
                       "the goal target keyboard has no Done key\n\(app.debugDescription)")
    }
}
