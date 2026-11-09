import XCTest

/// Add opens as a sheet: a swipe down on the grabber closes it like Cancel, except while a form holds typed input.
final class AddSheetUITests: XCTestCase {
    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        try super.tearDownWithError()
    }

    private func launchAndOpenAdd() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launch()
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let typeIt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch
        XCTAssertTrue(openAddScreen(in: app, until: typeIt), "the Add screen did not open")
        return (app, typeIt)
    }

    private func swipeSheetDown(_ app: XCUIApplication) {
        let top = app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
    }

    func testSwipeDownClosesAnAddWithNothingTyped() throws {
        let (app, typeIt) = launchAndOpenAdd()
        swipeSheetDown(app)
        XCTAssertTrue(typeIt.waitForNonExistence(timeout: 10), "a swipe down did not close Add")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "the tab bar is not back")
    }

    func testSwipeDownKeepsAFormWithTypedInput() throws {
        let (app, typeIt) = launchAndOpenAdd()
        typeIt.tap()
        XCTAssertTrue(app.navigationBars["Log entry"].waitForExistence(timeout: 20), "the details screen did not open")
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20), "the details form has no name field")
        name.tap()
        name.typeText("Oat")
        swipeSheetDown(app)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(app.navigationBars["Log entry"].exists, "the swipe closed the form")
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "Oat", "the typed text was lost")
        let back = app.navigationBars["Log entry"].buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Cancel")).firstMatch
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons["Discard"].waitForExistence(timeout: 5), "Cancel did not ask Discard this entry?")
    }
}
