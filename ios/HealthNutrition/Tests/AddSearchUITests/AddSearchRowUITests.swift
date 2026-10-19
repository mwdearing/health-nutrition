import XCTest

final class AddSearchRowUITests: XCTestCase {
    /// The search row sits at the top of Add. It must be on screen and hittable, and a tap must open
    /// product search with the field focused, so typing starts at once.
    func testSearchRowIsOnAddAndTapFocusesTheSearchField() throws {
        let app = XCUIApplication()
        app.launch()

        // A fresh install shows the welcome cover over Today until it is dismissed. Get started is what
        // a first-time user taps, so the test does the same before it looks for Add.
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        // Two buttons share this label and the first one is not hittable, so the tap went nowhere. Pick
        // the hittable one, and wait for it to become hittable rather than tapping straight away.
        let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        let hittableAdd = NSPredicate(format: "isHittable == true")
        let addButton = addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        if addButton == nil {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !addCandidates.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
        }
        let tappable = addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(tappable, "no hittable Add button on the Today screen (matching: \(hittableAdd))")
        tappable?.tap()

        // Matched by identifier: the Library picker and Library carry the same "Search foods" label.
        let row = app.buttons["addSearchRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the search row is not on the Add screen. \(describeAddState(app))")
        XCTAssertTrue(row.isHittable, "the search row is on screen but cannot be tapped")
        row.tap()

        let field = app.textFields["Search foods and products"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "product search did not open")
        // The field takes focus after a short delay, so poll for it rather than checking once.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focused, object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed,
                       "the search field did not take focus after the row was tapped")
    }

    /// The Add-related buttons, the tab bar and the sheet count, so a failure says what was on screen.
    private func describeAddState(_ app: XCUIApplication) -> String {
        let buttons = app.buttons.allElementsBoundByIndex
            .map { "\($0.label)|id=\($0.identifier)|hittable=\($0.isHittable)" }
            .filter { $0.localizedCaseInsensitiveContains("add") || $0.localizedCaseInsensitiveContains("search") || $0.localizedCaseInsensitiveContains("started") || $0.localizedCaseInsensitiveContains("restore") }
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }
        return "Add-related buttons: [\(buttons.joined(separator: "; "))] tab bar: [\(tabs.joined(separator: ", "))] sheets: \(app.sheets.count)"
    }
}
