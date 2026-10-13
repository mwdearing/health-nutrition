import XCTest

final class PrivacyShieldUITests: XCTestCase {
    func testSyntheticSheetIsShieldedOnDeactivationAndRestoredOnReturn() throws {
        let app = launchPrivacyFixture()
        let before = activations(in: app)
        app.buttons["Show synthetic sheet"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))

        // Pulling Notification Center down deactivates the scene while the app stays in the foreground.
        // The simulator draws system UI over the app, so the shield cannot be photographed there: the
        // fixture counts how often the shield window was raised, and the real app-switcher snapshot is
        // checked on a device (see docs/privacy-manifest.md).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        Thread.sleep(forTimeInterval: 1.5)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)))
        app.activate()

        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))
        app.buttons["close-synthetic-sheet"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-entry-marker"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(activations(in: app), before, "the shield was never raised on deactivation")
    }

    func testSyntheticAuthenticationReturnSheetDoesNotLeaveShieldStuck() {
        let app = launchPrivacyFixture()
        app.buttons["show-auth-return-fixture"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))
        app.buttons["close-synthetic-sheet"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-entry-marker"].exists)
    }

    private func launchPrivacyFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--privacy-shield-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["synthetic-entry-marker"].waitForExistence(timeout: 10))
        return app
    }

    private func activations(in app: XCUIApplication) -> Int {
        let label = app.staticTexts["shield-activation-count"].label
        return Int(label.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") ?? -1
    }
}
