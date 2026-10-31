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

    /// Opens Add and then "Type it in", the path to the form with the amount field. Each tap waits for its target
    /// to be hittable, and the form's own "Log entry" bar confirms it opened, with one more tap if the first was
    /// dropped during Add's presentation; a tap that lands mid-animation otherwise leaves no form to query.
    private func openTypedInEntryForm(_ app: XCUIApplication) throws {
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        var add: XCUIElement?
        _ = waitUntil(timeout: 20) {
            add = addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
            return add != nil
        }
        try XCTUnwrap(add, "no hittable Add button on Today").tap()

        let typeIt = app.buttons["Type it in"]
        let typeItReady = waitUntil(timeout: 20) { typeIt.exists && typeIt.isHittable }
        XCTAssertTrue(typeItReady, "Type it in is not tappable on Add")
        typeIt.tap()
        let form = app.navigationBars["Log entry"]
        // Retry only when the form is still absent and "Type it in" is still hittable; re-checking
        // the form right before the tap keeps a slow but successful open from a second tap.
        if !form.waitForExistence(timeout: 10), !form.exists, typeIt.exists, typeIt.isHittable { typeIt.tap() }
        XCTAssertTrue(form.waitForExistence(timeout: 20), "the typed-in entry form did not open")
    }

    /// Polls `condition` until it holds or `timeout` seconds pass; true when it held.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
