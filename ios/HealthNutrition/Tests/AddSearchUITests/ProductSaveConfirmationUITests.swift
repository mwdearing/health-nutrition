import XCTest

/// Saving a product edit from the Library's editor sheet confirms with "Product saved".
/// One fixed product is used for every run: it is created only when Library does not already hold it, so the
/// store grows by at most one row. The edit changes only the brand, and the teardown restores the brand through
/// the same editor.
final class ProductSaveConfirmationUITests: XCTestCase {
    private let productName = "Synthetic save test"
    private let editedBrand = "Synthetic brand"

    func testEditingAProductFromLibraryConfirmsTheSave() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), "no Library tab")
        libraryTab.tap()

        // Teardown runs in reverse order, so this restore runs before the app is terminated.
        addTeardownBlock { [self] in
            guard app.state == .runningForeground else { return }
            if openEditor(app) {
                let brand = app.textFields["Brand (optional)"]
                if brand.waitForExistence(timeout: 5) {
                    brand.tap()
                    if let current = brand.value as? String, !current.isEmpty, current != "Brand (optional)" {
                        brand.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
                    }
                }
                let save = app.buttons["Save product on this device"]
                scrollUntilHittable(save, in: app)
                if save.isHittable { save.tap() }
            }
        }

        XCTAssertTrue(ensureProductExists(in: app), "the fixed test product could not be created or found")

        XCTAssertTrue(openEditor(app), "the test product has no Edit and sharing review action")

        let brand = app.textFields["Brand (optional)"]
        XCTAssertTrue(brand.waitForExistence(timeout: 10), "the product editor did not open for the edit")
        brand.tap()
        brand.typeText(editedBrand)

        let save = app.buttons["Save product on this device"]
        scrollUntilHittable(save, in: app)
        XCTAssertTrue(save.isHittable, "Save product on this device is not reachable\n\(app.debugDescription)")
        save.tap()

        XCTAssertTrue(app.staticTexts["Product saved"].waitForExistence(timeout: 10),
                      "saving an edit from the Library did not confirm with Product saved\n\(app.debugDescription)")
    }

    /// Creates the fixed product unless Library already holds it. True when the product exists afterwards.
    private func ensureProductExists(in app: XCUIApplication) -> Bool {
        let search = app.textFields["Search on this device"]
        if search.waitForExistence(timeout: 10) {
            search.tap()
            search.typeText(productName)
            if app.buttons["Edit and sharing review"].waitForExistence(timeout: 5) { return true }
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: productName.count))
        }

        let createProduct = app.buttons["Create product"]
        guard createProduct.waitForExistence(timeout: 10) else { return false }
        createProduct.tap()

        let nameField = app.textFields["Name"]
        guard nameField.waitForExistence(timeout: 10) else { return false }
        nameField.tap()
        nameField.typeText(productName)

        let save = app.buttons["Save product on this device"]
        scrollUntilHittable(save, in: app)
        guard save.isHittable else { return false }
        save.tap()
        return app.buttons["Edit and sharing review"].waitForExistence(timeout: 15)
    }

    /// Opens the editor for the fixed product from its Library row.
    private func openEditor(_ app: XCUIApplication) -> Bool {
        // Narrow Library to the fixed product by name, so the Edit button tapped is this product's and not another row's.
        let search = app.textFields["Search on this device"]
        if search.waitForExistence(timeout: 5) {
            search.tap()
            if let current = search.value as? String, !current.isEmpty, current != "Search on this device" {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            search.typeText(productName)
        }
        let editRow = app.buttons["Edit and sharing review"].firstMatch
        guard editRow.waitForExistence(timeout: 10) else { return false }
        editRow.tap()
        return app.textFields["Name"].waitForExistence(timeout: 10)
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
