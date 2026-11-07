import XCTest

/// A screen with several amount fields has one keyboard Done key, not one per field. SwiftUI stacks a keyboard toolbar
/// for every field that attaches one, so the Amounts only screen (four amount fields) counted four Done keys on the
/// keyboard before its fields shared a single toolbar.
final class SingleKeyboardDoneUITests: XCTestCase {
    func testAmountsOnlyShowsOneKeyboardDoneKey() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let amountsOnly = app.buttons["Amounts only"]
        XCTAssertTrue(
            openAddScreen(in: app, until: amountsOnly), "the Amounts only quick action is not on the Add screen")
        amountsOnly.tap()
        XCTAssertTrue(app.navigationBars["Amounts only"].waitForExistence(timeout: 10), "the Amounts only screen did not open")

        let calories = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Calories")).firstMatch
        XCTAssertTrue(calories.waitForExistence(timeout: 10), "no Calories field\n\(app.debugDescription)")
        var attempts = 0
        repeat {
            calories.tap()
            attempts += 1
        } while !pollUntil(timeout: 3, { app.keyboards.count > 0 }) && attempts < 4
        XCTAssertTrue(app.keyboards.count > 0, "no software keyboard (is a hardware keyboard attached to the simulator?)")

        // Only a Done in the lower part of the screen belongs to the keyboard.
        let lowerPart = app.windows.firstMatch.frame.height * 0.4
        let keyboardDone = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY > lowerPart }
        XCTAssertEqual(keyboardDone.count, 1, "the keyboard should carry one Done key\n\(app.debugDescription)")
    }
}
