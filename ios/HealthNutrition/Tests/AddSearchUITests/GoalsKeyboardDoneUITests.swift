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
        // Edit goals opens Settings with the Daily goals screen pushed over it, or on the Settings form itself. The test
        // waits for the Daily goals screen by its navigation bar, one wait on a slow runner instead of a field query
        // repeated every two seconds (a repeated query timed out while evaluating on a slow simulator, runs 41985033734
        // and 41959425049), and taps the Daily goals row only if the screen did not open.
        let goalsBar = app.navigationBars["Daily goals"]
        if !(goalsBar.waitForExistence(timeout: 10) || field.exists) {
            let dailyGoals = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Daily goals")).firstMatch
            XCTAssertTrue(dailyGoals.waitForExistence(timeout: 15), "no Daily goals row in Settings")
            dailyGoals.tap()
            XCTAssertTrue(goalsBar.waitForExistence(timeout: 20), "the Daily goals screen did not open")
        }
        // A list only builds the rows near the screen, so the goal rows are scrolled into view.
        _ = field.waitForExistence(timeout: 15)
        var swipes = 0
        while !(field.exists && field.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
            _ = field.waitForExistence(timeout: 3)
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
