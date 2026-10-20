import XCTest

/// On the Add intake form, a labelled field reads its visible title, and the controls beside it keep their own
/// names. The amount field is the primary field; the Unit picker sits beside it in the same row.
final class AddIntakeLabelUITests: XCTestCase {
    func testAmountFieldReadsItsTitleAndTheUnitPickerKeepsItsName() throws {
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

        let typeIt = app.buttons["Type it in"]
        XCTAssertTrue(typeIt.waitForExistence(timeout: 10), "the Type it in quick action is not on the Add screen")
        typeIt.tap()

        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "the amount field is not on the Add intake form")
        XCTAssertEqual(amount.label, "Amount", "the amount field does not read its visible title")

        // The unit picker is a separate control in the same row: it keeps its own name.
        let unit = app.popUpButtons["Unit"].firstMatch
        let unitAsButton = app.buttons["Unit"].firstMatch
        XCTAssertTrue(unit.exists || unitAsButton.exists, "the Unit picker lost its own name")
    }
}
