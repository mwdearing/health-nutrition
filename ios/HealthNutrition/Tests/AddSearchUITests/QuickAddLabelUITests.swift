import XCTest

/// The amounts-only form's name field reads its visible title, so VoiceOver and UI tests name it while typing.
final class QuickAddLabelUITests: XCTestCase {
    func testAmountsOnlyNameFieldReadsItsTitle() throws {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

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

        let name = app.textFields["Name (optional)"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the name field does not read its visible title")
    }
}
