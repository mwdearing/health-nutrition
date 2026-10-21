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
        // Put the keyboard away first: with it up the edge drag did not reach the pop gesture, which hid a pop.
        if app.keyboards.count > 0 {
            let done = app.keyboards.buttons["Done"].firstMatch
            if done.exists { done.tap() } else { app.navigationBars["Log entry"].tap() }
            XCTAssertTrue(!app.keyboards.firstMatch.exists, "the keyboard did not go away before the swipe")
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        let askedFirst = app.buttons["Discard"].waitForExistence(timeout: 3)
        let stillThere = app.navigationBars["Log entry"].exists && app.textFields.firstMatch.value as? String == "Oat"
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
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(app.buttons["Type it in"].waitForExistence(timeout: 5) || !app.navigationBars["Log entry"].exists,
                      "a clean details form did not pop back on an edge swipe, so the gesture stayed off")
    }
}

/// Once a form is pushed, its own navigation bar shows exactly one leading control, Back or Cancel.
private func assertOneLeadingControl(_ app: XCUIApplication, bar: String, file: StaticString = #filePath, line: UInt = #line) {
    let navBar = app.navigationBars[bar]
    XCTAssertTrue(navBar.waitForExistence(timeout: 10), "\(bar) bar is missing", file: file, line: line)
    let leading = navBar.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Cancel"))
    XCTAssertEqual(leading.count, 1, "\(bar) shows \(leading.count) leading controls, expected one", file: file, line: line)
}
