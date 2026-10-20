import XCTest

/// The amounts-only form's name field reads its visible title, so VoiceOver and UI tests name it while typing.
final class QuickAddLabelUITests: XCTestCase {
    func testAmountsOnlyNameFieldReadsItsTitle() throws {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        // Two buttons share this label and the first is not hittable, so wait for the hittable one.
        let addButton = app.buttons.matching(
            NSPredicate(format: "label == %@ AND isHittable == true", "Add food, drink, or supplement")).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "no hittable Add button on the Today screen")
        addButton.tap()

        let amountsOnly = app.buttons["Amounts only"]
        XCTAssertTrue(amountsOnly.waitForExistence(timeout: 10), "the Amounts only quick action is not on the Add screen")
        amountsOnly.tap()

        let name = app.textFields["Name (optional)"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the name field does not read its visible title")
    }
}
