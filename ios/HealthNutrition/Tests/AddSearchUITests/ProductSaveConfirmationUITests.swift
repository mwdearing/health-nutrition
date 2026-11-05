import XCTest

/// Saving a product edit from the Library's editor sheet confirms with "Product saved".
/// One fixed product is used for every run. It is created only when no row for it exists, so the product itself
/// is never duplicated. Each run still saves two revisions (the edit and the restore). The edit changes only the
/// brand, and the teardown restores the brand value read before the edit.
final class ProductSaveConfirmationUITests: XCTestCase {
    private let productName = "Synthetic save test"
    private let editedBrand = "Synthetic brand"
    /// The brand the product had before this test edited it, read from the editor before any change.
    private var brandBeforeEdit = ""

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
            guard openEditor(app) else { return }
            let brand = app.textFields["Brand (optional)"]
            guard brand.waitForExistence(timeout: 5) else { return }
            brand.tap()
            if let current = brand.value as? String, !current.isEmpty, current != "Brand (optional)" {
                brand.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            if !brandBeforeEdit.isEmpty { brand.typeText(brandBeforeEdit) }
            let save = app.buttons["Save product on this device"]
            scrollUntilHittable(save, in: app)
            if save.isHittable { save.tap() }
        }

        XCTAssertTrue(ensureProductExists(in: app), "the fixed test product could not be created or found")

        XCTAssertTrue(openEditor(app), "the test product has no Edit and sharing review action")

        let brand = app.textFields["Brand (optional)"]
        XCTAssertTrue(brand.waitForExistence(timeout: 10), "the product editor did not open for the edit")
        if let current = brand.value as? String, current != "Brand (optional)" {
            brandBeforeEdit = current
        }
        brand.tap()
        brand.typeText(editedBrand)

        let save = app.buttons["Save product on this device"]
        scrollUntilHittable(save, in: app)
        XCTAssertTrue(save.isHittable, "Save product on this device is not reachable\n\(app.debugDescription)")
        save.tap()

        XCTAssertTrue(app.staticTexts["Product saved"].waitForExistence(timeout: 10),
                      "saving an edit from the Library did not confirm with Product saved\n\(app.debugDescription)")
    }

    /// Creates the fixed product unless its Library row already exists. True when the product exists afterwards.
    private func ensureProductExists(in app: XCUIApplication) -> Bool {
        if productRow(app).waitForExistence(timeout: 5) { return true }

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
        return productRow(app).waitForExistence(timeout: 15)
    }

    /// Opens the editor from this product's own Library row, never another product's Edit button.
    private func openEditor(_ app: XCUIApplication) -> Bool {
        let row = productRow(app)
        scrollUntilHittable(row, in: app)
        let editRow = row.buttons["Edit and sharing review"]
        guard editRow.waitForExistence(timeout: 10) else { return false }
        editRow.tap()
        return app.textFields["Name"].waitForExistence(timeout: 10)
    }

    /// The Library row whose label contains the fixed product's name.
    private func productRow(_ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", productName)).firstMatch
    }
}

/// Swipes up until the element can be tapped, for a list or form whose rows are built on demand.
private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
    var swipes = 0
    while !(element.exists && element.isHittable), swipes < 8 {
        app.swipeUp()
        swipes += 1
    }
}
