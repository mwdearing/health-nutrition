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
        // Settings opens with its quick-water field above the goals, and a list only builds the rows near the screen,
        // so the goal rows are scrolled into view.
        var swipes = 0
        while !field.waitForExistence(timeout: 2), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(field.exists, "no goal target field on the Daily goals screen\n\(app.debugDescription)")
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
