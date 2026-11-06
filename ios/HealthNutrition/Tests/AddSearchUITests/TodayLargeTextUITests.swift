import XCTest

/// At the largest accessibility text size the Today hero stays inside the screen: neither the hero nor its Food row
/// runs off the side, and the screen keeps its name in the navigation bar. Measured on an empty Today, so it needs
/// no goal saved.
final class TodayLargeTextUITests: XCTestCase {
    func testTheHeroFitsTheScreenAtTheLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window")
        let hero = element("todayHero", in: app)
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "no Today hero")
        let foodRow = element("calorieFoodBurnedRow", in: app)
        XCTAssertTrue(foodRow.waitForExistence(timeout: 10), "no Food row in the hero")

        let screen = window.frame, box = hero.frame, row = foodRow.frame
        XCTAssertGreaterThanOrEqual(box.minX, screen.minX - 0.5, "the hero starts left of the screen")
        XCTAssertLessThanOrEqual(box.maxX, screen.maxX + 0.5, "the hero runs off the right of the screen")
        XCTAssertGreaterThanOrEqual(row.minX, box.minX - 0.5, "the Food row starts outside the hero")
        XCTAssertLessThanOrEqual(row.maxX, box.maxX + 0.5, "the Food row runs outside the hero")
        XCTAssertTrue(app.navigationBars["Today"].exists, "the navigation bar lost the screen name")
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
