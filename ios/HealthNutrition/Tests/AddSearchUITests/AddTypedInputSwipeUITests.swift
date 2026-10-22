import XCTest

/// A typed Add entry must not be lost to an edge swipe-back. The test types a name into the details
/// form, drags from the left screen edge, and then checks that either the discard question is up or the
/// form is still on screen with its typed text.
final class AddTypedInputSwipeUITests: XCTestCase {
    /// Ends the app after each test so a leftover app cannot carry its typed state into the next run.
    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        try super.tearDownWithError()
    }

    func testEdgeSwipeBackKeepsTypedDetailsOrAsksFirst() throws {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !addCandidates.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let add = addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(add, "no hittable Add button on Today")
        add?.tap()

        let typeIt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch
        XCTAssertTrue(typeIt.waitForExistence(timeout: 10), "the Type it in tile is not on Add")
        typeIt.tap()

        // Wait for the details screen itself before looking for its field, so a slow push is not read as a missing field.
        XCTAssertTrue(app.navigationBars["Log entry"].waitForExistence(timeout: 20), "the details screen did not open")
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20), "the details form has no name field")
        name.tap()
        name.typeText("Oat")

        // Drag from the left edge to the middle: the edge swipe-back gesture.
        assertOneLeadingControl(app, bar: "Log entry")
        // Put the keyboard away first: a tap on the form background dismisses it, and the edge drag only pops
        // when no keyboard is up. Return is the fallback for a text keyboard that a background tap leaves up.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        if app.keyboards.buttons["Return"].firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tap() }
        // The swipe must not run against a keyboard: wait for it to be gone, and fail the test if it is not.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "the keyboard did not go away before the swipe")
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        // Wait for the outcome, not a fixed time: either the discard question shows, or the screen has left the form.
        let discard = app.buttons["Discard"]
        let bar = app.navigationBars["Log entry"]
        let outcomeDeadline = Date().addingTimeInterval(5)
        while Date() < outcomeDeadline, !discard.exists, bar.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        // Positive check: the question is up, or the form is still there with its typed text intact.
        let askedFirst = discard.exists
        let stillThere = bar.exists && app.textFields.firstMatch.value as? String == "Oat"
        XCTAssertTrue(askedFirst || stillThere,
                      "the edge swipe popped the details form and lost the typed name without asking")
    }

    /// The gate must switch off only while there is typed input: on a clean details form the edge drag
    /// still pops back to Add, so the gesture is known to work again once the form is clean.
    func testEdgeSwipeBackStillWorksOnACleanDetailsForm() throws {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !addCandidates.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })?.tap()

        let typeIt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch
        XCTAssertTrue(typeIt.waitForExistence(timeout: 10), "the Type it in tile is not on Add")
        typeIt.tap()

        XCTAssertTrue(app.navigationBars["Log entry"].waitForExistence(timeout: 10), "the details form did not open")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)

        // The pop itself: back on Add, the Type it in tile is on screen again.
        let typeItAgain = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch
        XCTAssertTrue(typeItAgain.waitForExistence(timeout: 10), "a clean details form did not pop back to Add on an edge swipe")
    }
}

/// Once a form is pushed, its own navigation bar shows exactly one leading control, Back or Cancel.
private func assertOneLeadingControl(_ app: XCUIApplication, bar: String, file: StaticString = #filePath, line: UInt = #line) {
    let navBar = app.navigationBars[bar]
    XCTAssertTrue(navBar.waitForExistence(timeout: 10), "\(bar) bar is missing", file: file, line: line)
    let leading = navBar.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Cancel"))
    XCTAssertEqual(leading.count, 1, "\(bar) shows \(leading.count) leading controls, expected one", file: file, line: line)
}
