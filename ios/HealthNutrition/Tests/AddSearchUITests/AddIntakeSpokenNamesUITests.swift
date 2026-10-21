import XCTest

final class AddIntakeSpokenNamesUITests: XCTestCase {
    /// The amount field is named "Amount" for VoiceOver, and the Unit picker keeps its own name. The field and
    /// the picker share one form row, so the field's name must not take the picker's.
    func testAmountFieldIsNamedAmountAndTheUnitPickerKeepsItsName() throws {
        let app = XCUIApplication()
        app.launch()
        try openTypedInEntryForm(app)

        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "the amount field is not named Amount")
        XCTAssertEqual(amount.label, "Amount")

        // Any element named Unit that is not plain text. A stray static text with that name would not pass.
        let unit = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND elementType != %d", "Unit", XCUIElement.ElementType.staticText.rawValue)).firstMatch
        if !unit.exists {
            // Diagnostic: the element tree, so the CI log shows what the Unit picker exposes.
            let dump = app.debugDescription
            let attachment = XCTAttachment(string: dump)
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("the Unit picker lost its own name. Element tree: \(dump)")
        }
    }

    /// The barcode field is named "Barcode (optional)" and the Look up button keeps its own name. The app always
    /// has a barcode lookup, so the field is shown on the typed-in form without any launch setup.
    func testBarcodeFieldIsNamedBarcodeAndLookUpKeepsItsName() throws {
        let app = XCUIApplication()
        app.launch()
        try openTypedInEntryForm(app)

        let barcode = app.textFields["Barcode (optional)"]
        XCTAssertTrue(barcode.waitForExistence(timeout: 10), "the barcode field is not named Barcode (optional)")
        XCTAssertEqual(barcode.label, "Barcode (optional)")

        let lookUp = app.buttons["Look up barcode"]
        XCTAssertTrue(lookUp.exists, "the Look up button lost its name")
    }

    /// Opens Add and then "Type it in", the path to the form with the amount field.
    private func openTypedInEntryForm(_ app: XCUIApplication) throws {
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let addButton = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
            .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        let add = try XCTUnwrap(addButton, "no hittable Add button on Today")
        add.tap()
        let typeIt = app.buttons["Type it in"]
        XCTAssertTrue(typeIt.waitForExistence(timeout: 10), "Type it in is not on the Add screen")
        typeIt.tap()
    }
}
