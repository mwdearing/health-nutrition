import XCTest

/// Saving a product from the Library's editor sheet confirms with "Product saved" and leaves the editor.
/// The product is created in the test, edited once, and the edit is undone in the teardown.
final class ProductSaveConfirmationUITests: XCTestCase {
    func testEditingAProductFromLibraryConfirmsTheSave() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), "no Library tab")
        libraryTab.tap()

        let createProduct = app.buttons["Create product"]
        XCTAssertTrue(createProduct.waitForExistence(timeout: 10), "Library has no Create product action")
        createProduct.tap()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "the product editor did not open")
        nameField.tap()
        nameField.typeText("Synthetic save test")

        let save = app.buttons["Save product on this device"]
        scrollUntilHittable(save, in: app)
        save.tap()

        // The new product is listed in the Library; open its editor from its row.
        let editRow = app.buttons["Edit and sharing review"].firstMatch
        XCTAssertTrue(editRow.waitForExistence(timeout: 15), "the saved product has no Edit and sharing review action")
        editRow.tap()

        let editName = app.textFields["Name"]
        XCTAssertTrue(editName.waitForExistence(timeout: 10), "the product editor did not open for the edit")
        editName.tap()
        editName.typeText(" two")

        scrollUntilHittable(save, in: app)
        save.tap()

        XCTAssertTrue(app.staticTexts["Product saved"].waitForExistence(timeout: 10),
                      "saving an edit from the Library did not confirm with Product saved\n\(app.debugDescription)")
    }
}

/// Swipes up until the element can be tapped, for a form whose rows are built on demand.
private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
    var swipes = 0
    while !(element.exists && element.isHittable), swipes < 8 {
        app.swipeUp()
        swipes += 1
    }
}
