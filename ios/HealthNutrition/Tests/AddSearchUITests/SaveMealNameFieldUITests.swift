import XCTest

/// The Save as meal name field is named "Meal name" for VoiceOver. Its example text is the prompt, not the name.
/// The test logs one amounts-only entry, names it through Save as meal, and removes the entry through the UI.
final class SaveMealNameFieldUITests: XCTestCase {
    func testSaveAsMealNameFieldIsNamedMealName() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }
        // Registered after terminate, so it runs first: the entry is removed through the Diary before the app quits.
        addTeardownBlock { self.deleteFirstDiaryEntry(app) }

        try logAmountsOnlyEntry(app)
        let diary = app.tabBars.buttons["Diary"]
        XCTAssertTrue(diary.waitForExistence(timeout: 10), "the Diary tab is not on screen after logging")
        diary.tap()

        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Save ", " as a meal")).firstMatch
        if !save.waitForExistence(timeout: 10) {
            XCTFail("no Save as meal button after logging an entry. Element tree: \(app.debugDescription)")
        }
        save.tap()

        let name = app.textFields["Meal name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the Save as meal field is not named Meal name")
        XCTAssertEqual(name.label, "Meal name", "the Save as meal field is named by its example, not by Meal name")
        app.buttons["Cancel"].tap()
    }

    private func logAmountsOnlyEntry(_ app: XCUIApplication) throws {
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        // Two buttons share this label and the first is not hittable, so wait for the hittable one.
        let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !addCandidates.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let addButton = addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(addButton, "no hittable Add button on the Today screen")
        addButton?.tap()

        let amountsOnly = app.buttons["Amounts only"]
        XCTAssertTrue(amountsOnly.waitForExistence(timeout: 10), "the Amounts only quick action is not on the Add screen")
        amountsOnly.tap()

        let calories = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Calories")).firstMatch
        XCTAssertTrue(calories.waitForExistence(timeout: 10), "the calories field is not on the Amounts only form")
        calories.tap()
        calories.typeText("100")

        let log = app.buttons["Log"]
        XCTAssertTrue(log.waitForExistence(timeout: 5), "the Log button is not on the Amounts only form")
        log.tap()
        // Logging leaves the Add sheet open on the Today screen; close it so the tabs are reachable.
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }

    /// Removes the first entry in the Diary with a swipe and Delete, the way the person would.
    private func deleteFirstDiaryEntry(_ app: XCUIApplication) {
        let diary = app.tabBars.buttons["Diary"]
        guard diary.waitForExistence(timeout: 5) else { return }
        diary.tap()
        let row = app.cells.firstMatch
        guard row.waitForExistence(timeout: 5) else { return }
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        if delete.waitForExistence(timeout: 3) { delete.tap() }
    }
}
