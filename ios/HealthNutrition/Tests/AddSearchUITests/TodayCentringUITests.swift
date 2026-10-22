import XCTest

/// The Today header (title and date) and the macro columns are centred on the screen. Measured with the
/// on-screen frames XCUITest reports, so it checks the layout the person sees rather than the view tree.
final class TodayCentringUITests: XCTestCase {
    /// Points allowed between the centre of an element and the centre of the window.
    private let tolerance: CGFloat = 1

    func testTheTitleAndDateAreCentredOnTheScreen() throws {
        let app = launchToToday()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window")
        let windowMidX = window.frame.midX

        for identifier in ["todayHeader", "todayDate"] {
            let element = element(identifier, in: app)
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) is not on screen")
            let midX = element.frame.midX
            XCTAssertEqual(
                midX, windowMidX, accuracy: tolerance,
                "\(identifier) midX \(midX) is not within \(tolerance) pt of the window midX \(windowMidX)")
        }
    }

    /// A calorie goal with no macro goals: the calorie block is centred on its own, without the macro columns.
    func testTheCalorieBlockIsCentredWithAGoalAndNoMacroGoals() throws {
        let app = launchToToday()
        assertNoCalorieSummaryOrMacroColumns(app, "before any goal is set")
        guard setGoals(app, targets: [("Energy", "2357")]) else { return }
        addTeardownBlock { try self.clearGoals(app) }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window")
        let windowMidX = window.frame.midX
        for identifier in ["calorieRemainingFigure", "calorieRemainingLabel", "calorieGoalLine", "calorieFoodBurnedRow"] {
            let element = element(identifier, in: app)
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) is not on screen with a calorie goal")
            let midX = element.frame.midX
            XCTAssertEqual(
                midX, windowMidX, accuracy: tolerance,
                "\(identifier) midX \(midX) is not within \(tolerance) pt of the window midX \(windowMidX)")
        }
    }

    func testEachMacroColumnIsCentredInItsOwnEqualColumn() throws {
        let app = launchToToday()
        assertNoCalorieSummaryOrMacroColumns(app, "before any goal is set")
        guard setGoals(app) else { return }
        // Teardown blocks run last in first-in-last-out order, so this clear runs before the app terminates
        // (registered in launchToToday), and runs even when an assertion below fails.
        addTeardownBlock { try self.clearGoals(app) }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window")
        // The calorie block the screenshot circles: the figure, its label, the goal line and the Food/Burned row.
        for identifier in ["calorieRemainingFigure", "calorieRemainingLabel", "calorieGoalLine", "calorieFoodBurnedRow"] {
            let element = element(identifier, in: app)
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) is not on screen after the goals are saved")
            let midX = element.frame.midX
            XCTAssertEqual(
                midX, windowMidX, accuracy: tolerance,
                "\(identifier) midX \(midX) is not within \(tolerance) pt of the window midX \(windowMidX)")
        }
        var widths: [CGFloat] = []
        for nutrient in ["Protein", "Carbohydrate", "Fat"] {
            let column = element("macroColumn-\(nutrient)", in: app)
            XCTAssertTrue(column.waitForExistence(timeout: 10), "macroColumn-\(nutrient) is not on screen after the goals are saved")
            let label = element("macroLabel-\(nutrient)", in: app)
            let figure = element("macroFigure-\(nutrient)", in: app)
            XCTAssertTrue(label.waitForExistence(timeout: 10), "macroLabel-\(nutrient) is not on screen")
            XCTAssertTrue(figure.waitForExistence(timeout: 10), "macroFigure-\(nutrient) is not on screen")
            XCTAssertEqual(
                label.frame.midX, column.frame.midX, accuracy: tolerance,
                "\(nutrient) label midX \(label.frame.midX) is not within \(tolerance) pt of its column midX \(column.frame.midX)")
            XCTAssertEqual(
                figure.frame.midX, column.frame.midX, accuracy: tolerance,
                "\(nutrient) figure midX \(figure.frame.midX) is not within \(tolerance) pt of its column midX \(column.frame.midX)")
            widths.append(column.frame.width)
        }
        let first = try XCTUnwrap(widths.first)
        for width in widths {
            XCTAssertEqual(width, first, accuracy: tolerance, "the three macro columns differ in width: \(widths)")
        }
    }

    /// Launches the app, dismisses onboarding if it shows, and waits for the Today screen's header.
    private func launchToToday() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // Registered first, so it runs last: the app terminates after any goals are cleared.
        addTeardownBlock { app.terminate() }
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        XCTAssertTrue(element("todayHeader", in: app).waitForExistence(timeout: 15), "the Today header did not appear")
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The calorie summary and macro columns are absent until a calorie goal and macro goals are set.
    private func assertNoCalorieSummaryOrMacroColumns(_ app: XCUIApplication, _ when: String) {
        for identifier in ["calorieRemainingFigure", "calorieRemainingLabel", "calorieGoalLine", "macroColumn-Protein"] {
            XCTAssertFalse(element(identifier, in: app).exists, "\(identifier) is on screen \(when)")
        }
    }

    /// Opens Daily goals and enters a calorie goal and Protein, Carbohydrate and Fat gram goals, as a person would.
    /// Returns false when a step could not be reached; the caller then stops, so one miss is reported once.
    private func setGoals(_ app: XCUIApplication, targets: [(name: String, value: String)] = [
        ("Energy", "2357"), ("Protein", "90"), ("Carbohydrate", "250"), ("Fat", "70"),
    ]) -> Bool {
        let editGoals = app.buttons["Edit goals"]
        XCTAssertTrue(editGoals.waitForExistence(timeout: 10), "the Edit goals link is not on Today")
        editGoals.tap()
        // The Goals screen's navigation title is "Daily goals" (GoalsView.swift). The List can scroll the intro line
        // off screen, so the title is what this waits on. A miss dumps the element tree into the failure message.
        guard app.navigationBars["Daily goals"].waitForExistence(timeout: 10) else {
            XCTFail("the Goals screen did not open from Edit goals. Screen: \(app.debugDescription)")
            return false
        }
        for (name, value) in targets {
            let field = app.textFields["Daily target for \(name)"]
            // One failure per missing field: XCTFail and stop, so a single miss is not reported twice.
            guard field.waitForExistence(timeout: 10) else {
                XCTFail("the \(name) target field is not on the Goals screen. Screen: \(app.debugDescription)")
                return false
            }
            field.tap()
            field.typeText(value)
            field.typeText("\n")
        }
        // Return to Today with the Goals screen's own back button, then wait for the calorie summary.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        guard element("calorieRemainingFigure", in: app).waitForExistence(timeout: 10) else {
            XCTFail("the calorie summary did not appear after the goals were saved")
            return false
        }
        return true
    }

    /// Clears every goal through Settings > Daily goals > Clear all goals, then confirms the empty state on Today.
    private func clearGoals(_ app: XCUIApplication) throws {
        if !app.buttons["Clear all goals"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let clearAll = app.buttons["Clear all goals"].firstMatch
        XCTAssertTrue(clearAll.waitForExistence(timeout: 10), "the Clear all goals button is not on screen")
        clearAll.tap()
        let confirm = app.sheets.buttons["Clear all goals"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the Clear all goals confirmation did not appear")
        confirm.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("todayHeader", in: app).waitForExistence(timeout: 10), "Today did not return after clearing")
        assertNoCalorieSummaryOrMacroColumns(app, "after Clear all goals")
    }
}
