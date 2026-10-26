import XCTest

final class AddIntakeSpokenNamesUITests: XCTestCase {
    /// The amount field is named "Amount" for VoiceOver, and the Unit picker keeps its own name. The field and
    /// the picker share one form row, so the field's name must not take the picker's.
    func testAmountFieldIsNamedAmountAndTheUnitPickerKeepsItsName() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }
        try openTypedInEntryForm(app)

        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "the amount field is not named Amount")
        XCTAssertEqual(amount.label, "Amount")

        // The Unit picker is a menu button named by its unit: "Unit, oz". Query that shape exactly, and require one.
        let unitButtons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Unit, "))
        if !unitButtons.firstMatch.exists {
            // Diagnostic: the element tree, so the CI log shows what the Unit picker exposes.
            let dump = app.debugDescription
            let attachment = XCTAttachment(string: dump)
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("the Unit picker lost its own name. Element tree: \(dump)")
            return
        }
        XCTAssertEqual(unitButtons.count, 1, "expected exactly one Unit picker button")
        let unit = unitButtons.firstMatch
        XCTAssertEqual(unit.label, "Unit, oz", "the Unit picker lost its own name, or its unit changed")
    }

    /// The barcode field is named "Barcode (optional)" and the Look up button keeps its own name. The field
    /// shows only when the form has a barcode lookup (AddIntakeView: canLookUpBarcode) and is not a custom
    /// product (!isCustomProduct). The shipped wiring always gives a lookup (RootView passes
    /// services.barcodeLookup, which is non-optional) and the typed-in path never sets a custom product, so the
    /// field shows here. The test does not control either condition; a change to them will fail it.
    func testBarcodeFieldIsNamedBarcodeAndLookUpKeepsItsName() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }
        try openTypedInEntryForm(app)

        let barcode = app.textFields["Barcode (optional)"]
        XCTAssertTrue(barcode.waitForExistence(timeout: 10), "the barcode field is not named Barcode (optional)")
        XCTAssertEqual(barcode.label, "Barcode (optional)")

        let lookUp = app.buttons["Look up barcode"]
        XCTAssertTrue(lookUp.waitForExistence(timeout: 10), "the Look up button lost its name")
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
