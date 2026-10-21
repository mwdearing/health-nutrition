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
            let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) is not on screen")
            let midX = element.frame.midX
            XCTAssertEqual(
                midX, windowMidX, accuracy: tolerance,
                "\(identifier) midX \(midX) is not within \(tolerance) pt of the window midX \(windowMidX)")
        }
    }

    func testEachMacroColumnIsCentredInItsOwnEqualColumn() throws {
        let app = launchToToday()
        var widths: [CGFloat] = []
        for nutrient in ["Protein", "Carbohydrate", "Fat"] {
            let column = app.descendants(matching: .any).matching(identifier: "macroColumn-\(nutrient)").firstMatch
            XCTAssertTrue(column.waitForExistence(timeout: 10), "macroColumn-\(nutrient) is not on screen")
            let label = app.descendants(matching: .any).matching(identifier: "macroLabel-\(nutrient)").firstMatch
            let figure = app.descendants(matching: .any).matching(identifier: "macroFigure-\(nutrient)").firstMatch
            XCTAssertTrue(label.exists, "macroLabel-\(nutrient) is not on screen")
            XCTAssertTrue(figure.exists, "macroFigure-\(nutrient) is not on screen")
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
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let header = app.descendants(matching: .any).matching(identifier: "todayHeader").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the Today header did not appear")
        return app
    }
}
