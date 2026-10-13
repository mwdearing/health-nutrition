import XCTest
import Vision

final class PrivacyShieldUITests: XCTestCase {
    func testSyntheticSheetIsShieldedInAppSwitcherAndRestoredOnReturn() throws {
        let app = launchPrivacyFixture()
        app.buttons["Show synthetic sheet"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The switcher opens from a bottom-edge swipe while the app is in the foreground. Pressing Home first
        // lands on the home screen, where the same swipe does nothing.
        openAppSwitcher(in: springboard)
        let screenshot = XCUIScreen.main.screenshot()
        attach(screenshot, named: "privacy-shield-app-switcher-synthetic-sheet")
        let capturedText = try recognizedText(in: screenshot)
        XCTAssertTrue(capturedText.localizedCaseInsensitiveContains("Screen hidden"), capturedText)
        XCTAssertFalse(capturedText.localizedCaseInsensitiveContains("Synthetic sheet marker"))
        XCTAssertFalse(capturedText.localizedCaseInsensitiveContains("protein 42g"))

        app.activate()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))
        app.buttons["close-synthetic-sheet"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-entry-marker"].exists)
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

    private func openAppSwitcher(in springboard: XCUIApplication) {
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.15, thenDragTo: end)
        // Let the switcher animation settle before the frame is captured. The recognized text asserted by the
        // caller is the guard that this frame is the switcher showing the shield, not the home screen.
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func recognizedText(in screenshot: XCUIScreenshot) throws -> String {
        guard let image = screenshot.image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
