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
    /// True only once the test has typed the edited brand. The teardown restores nothing until then.
    private var didEditBrand = false

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
            guard didEditBrand, app.state == .runningForeground else { return }
            guard openEditor(app) else { return }
            let brand = app.textFields["Brand (optional)"]
            guard brand.waitForExistence(timeout: 5) else { return }
            focus(brand)
            if let current = brand.value as? String, !current.isEmpty, current != "Brand (optional)" {
                brand.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            if !brandBeforeEdit.isEmpty { brand.typeText(brandBeforeEdit) }
            dismissKeyboard(app)
            let save = app.buttons["Save product on this device"]
            scrollUntilHittable(save, in: app)
            if save.isHittable { save.tap() }
        }

        XCTAssertTrue(ensureProductExists(in: app),
                      "the fixed test product could not be created or found\n\(app.debugDescription)")

        XCTAssertTrue(openEditor(app), "the test product has no Edit and sharing review action")

        let brand = app.textFields["Brand (optional)"]
        XCTAssertTrue(brand.waitForExistence(timeout: 10), "the product editor did not open for the edit")
        if let current = brand.value as? String, current != "Brand (optional)" {
            brandBeforeEdit = current
        }
        focus(brand)
        brand.typeText(editedBrand)
        didEditBrand = true
        dismissKeyboard(app)

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
        captureDiagnostics(app, "after Create product tap")

        let nameField = app.textFields["Name"]
        guard nameField.waitForExistence(timeout: 10) else { return false }
        nameField.tap()
        nameField.typeText(productName)
        captureDiagnostics(app, "after name typed")
        dismissKeyboard(app)

        let save = app.buttons["Save product on this device"]
        scrollUntilHittable(save, in: app)
        captureDiagnostics(app, "before Save scroll")
        guard save.isHittable else { captureDiagnostics(app, "Save not hittable"); return false }
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

    /// The Library row whose label contains the fixed product's name. Library rows are not always list cells, so
    /// the lookup falls back to any element containing the name.
    private func productRow(_ app: XCUIApplication) -> XCUIElement {
        // Library opens on the Favorites segment, where a new product does not appear. Products lists it.
        let products = app.buttons["Products"]
        if products.exists { products.tap() }
        let named = NSPredicate(format: "label CONTAINS %@", productName)
        let cell = app.cells.containing(named).firstMatch
        if cell.exists { return cell }
        return app.otherElements.containing(named).firstMatch
    }
}

/// Taps a text field until it holds keyboard focus, as the existing UI tests do, because a single tap can land while
/// the screen is still settling.
private func focus(_ field: XCUIElement) {
    func hasFocus() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
    field.tap()
    if !hasFocus() { field.tap() }
}

/// Swipes up until the element can be tapped, for a list or form whose rows are built on demand.
private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
    // The product editor is a sheet, so the swipe goes to the sheet. Without one, it goes to the Library's own
    // table or collection view. Swiping the Library behind an open sheet does nothing, which is why this is first.
    let container: XCUIElement
    if app.sheets.firstMatch.exists { container = app.sheets.firstMatch }
    else if app.tables.firstMatch.exists { container = app.tables.firstMatch }
    else if app.collectionViews.firstMatch.exists { container = app.collectionViews.firstMatch }
    else { container = app }
    var swipes = 0
    while !(element.exists && element.isHittable), swipes < 20 {
        container.swipeUp()
        swipes += 1
    }
}

/// Ends keyboard entry with the keyboard's Return key, so the form can scroll to the Save button beneath the keyboard.
private func dismissKeyboard(_ app: XCUIApplication) {
    guard app.keyboards.firstMatch.exists else { return }
    for label in ["Return", "return"] where app.keyboards.buttons[label].exists {
        app.keyboards.buttons[label].tap()
        return
    }
}

/// Logs the element tree and keeps a screenshot of the run, so a failure shows what the runner had on screen.
private func captureDiagnostics(_ app: XCUIApplication, _ label: String) {
    print("DIAG [\(label)] sheets=\(app.sheets.count) tables=\(app.tables.count) collectionViews=\(app.collectionViews.count)")
    print("DIAG [\(label)] \(app.debugDescription)")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "diag: \(label)"
    shot.lifetime = .keepAlways
    XCTContext.runActivity(named: "diag: \(label)") { $0.add(shot) }
}
