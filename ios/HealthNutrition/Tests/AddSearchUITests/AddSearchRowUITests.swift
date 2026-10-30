import XCTest

final class AddSearchRowUITests: XCTestCase {
    /// The search row sits at the top of Add. It must be on screen and hittable, and a tap must open
    /// product search with the field focused, so typing starts at once.
    func testSearchRowIsOnAddAndTapFocusesTheSearchField() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        // A fresh install shows the welcome cover over Today until it is dismissed. Get started is what
        // a first-time user taps, so the test does the same before it looks for Add.
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        // Matched by identifier: the Library picker and Library carry the same "Search foods" label. The shared
        // opener waits for a hittable Add button and retries a tap that landed while Today was still settling.
        let row = app.buttons["addSearchRow"]
        XCTAssertTrue(openAddScreen(in: app, until: row),
                      "the search row is not on the Add screen. \(describeAddState(app))")
        XCTAssertTrue(row.isHittable, "the search row is on screen but cannot be tapped")
        row.tap()

        let field = app.textFields["sharedProductSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "product search did not open")
        XCTAssertEqual(field.label, "Search foods", "the search field's label is not the agreed name")
        // The field takes focus after a short delay, and a busy simulator can take longer than a few seconds, so
        // wait for it to be hittable first, then allow a longer window for focus. A field that never takes focus
        // still fails here.
        let hittable = NSPredicate(format: "isHittable == true")
        let hittableWait = XCTNSPredicateExpectation(predicate: hittable, object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [hittableWait], timeout: 15), .completed,
                       "the search field did not become hittable after the row was tapped")
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focused, object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed,
                       "the search field did not take focus after the row was tapped")
    }

    /// Back from a pushed child must not raise the keyboard again (#944). The search screen focuses its field once,
    /// on its first appearance; a return after a push takes no focus. A fresh install has no pushable row on the
    /// search screen, so the test logs a typed entry first, which then shows under Recent with nothing sent anywhere.
    func testReturningToSearchAfterAPushDoesNotRaiseTheKeyboard() throws {
        let app = XCUIApplication()
        app.launch()
        // Teardown blocks run last-added first: the entry is deleted, then the app ends.
        addTeardownBlock { app.terminate() }
        // UI tests share one store, so the name is unique to this run and the entry is deleted again through the UI.
        let entryName = "Recent oats \(UUID().uuidString.prefix(6))"
        addTeardownBlock { self.deleteEntry(named: entryName, in: app) }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        // Precondition: no entry with this name exists yet, so the Recent row below can only be the one logged here.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", entryName)).firstMatch.exists,
                       "an entry named \(entryName) already exists before the test logs it")

        // Log one typed entry so the search screen has a Recent row to push.
        tapHittableAdd(app)
        let typeIt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch
        XCTAssertTrue(typeIt.waitForExistence(timeout: 10), "the Type it in tile is not on Add. \(describeAddState(app))")
        typeIt.tap()
        XCTAssertTrue(app.navigationBars["Log entry"].waitForExistence(timeout: 20), "the details screen did not open")
        // The Name field's title is not its spoken name (only opted-in fields are), so it is the form's first field.
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20), "the details form has no Name field")
        name.tap()
        name.typeText(entryName)
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "the details form has no Amount field")
        amount.tap()
        amount.typeText("2")
        // The decimal keypad has no Return key; its Done button puts it away so Log is not covered.
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
        let log = app.buttons["Log"]
        XCTAssertTrue(log.waitForExistence(timeout: 10), "the details form has no Log button")
        log.tap()
        XCTAssertTrue(app.navigationBars["Log entry"].waitForNonExistence(timeout: 20), "the entry was not logged")

        // Open search: the field takes focus once, on this first appearance.
        tapHittableAdd(app)
        let row = app.buttons["addSearchRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the search row is not on the Add screen. \(describeAddState(app))")
        row.tap()
        let field = app.textFields["sharedProductSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "product search did not open")
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 15), .completed, "the search field did not take focus on first open")

        // Push the Recent row, then come back.
        let recent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", entryName)).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "the logged entry is not under Recent on the search screen")
        recent.tap()
        let detailsBar = app.navigationBars["Log entry"]
        XCTAssertTrue(detailsBar.waitForExistence(timeout: 20), "tapping the Recent row did not open the details form")
        // The Recent row opens a prefilled form, so the form shows its own Back button and asks before discarding.
        let back = detailsBar.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the details form has no Back button")
        back.tap()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 5) { discard.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Back did not return to the search screen")

        // The focus request waits 400 ms after an appearance; wait well past it, then the field must not hold focus.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        // `hasKeyboardFocus` is read through key-value coding, as the Library search test does: it is not a public
        // XCUIElement property, so `field.hasKeyboardFocus` does not compile.
        XCTAssertFalse(
            (field.value(forKey: "hasKeyboardFocus") as? Bool) == true,
            "returning to the search screen after a push raised the keyboard")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a keyboard is up after returning to the search screen")
    }

    /// Deletes the entry this test logged, from Today, through the entry screen's Delete entry and its confirmation.
    /// Relaunches first, so it starts from Today whatever screen the test ended on. Does nothing if the entry was never logged.
    private func deleteEntry(named entryName: String, in app: XCUIApplication) {
        app.terminate()
        app.launch()
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", entryName)).firstMatch
        guard row.waitForExistence(timeout: 10) else { return }
        row.tap()
        let delete = app.buttons["Delete entry"]
        var swipes = 0
        while !(delete.exists && delete.isHittable) && swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(delete.exists, "teardown: the entry screen has no Delete entry button")
        delete.tap()
        // The confirmation button is spoken as "Confirm delete" (EntryDetailView), not by its title.
        let confirm = app.buttons["Confirm delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "teardown: the delete confirmation did not appear")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "teardown: the logged entry is still on Today")
    }

    /// Taps the hittable "Add food, drink, or supplement" button; two share the label and only one can be tapped.
    private func tapHittableAdd(_ app: XCUIApplication) {
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !candidates.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let add = candidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(add, "no hittable Add button. \(describeAddState(app))")
        add?.tap()
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
