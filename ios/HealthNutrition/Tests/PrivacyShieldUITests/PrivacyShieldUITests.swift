import XCTest
import Vision

final class PrivacyShieldUITests: XCTestCase {
    func testSyntheticSheetIsShieldedInAppSwitcherAndRestoredOnReturn() throws {
        let app = launchPrivacyFixture()
        app.buttons["Show synthetic sheet"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))

        // Notification Center pulled down from the top edge makes the scene inactive while the app stays in
        // the foreground. The simulator does not draw the app switcher for a synthesized swipe, but it does
        // send the inactive transition, which is the moment the shield has to be showing.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.5)
        let screenshot = XCUIScreen.main.screenshot()
        attach(screenshot, named: "privacy-shield-inactive-synthetic-sheet")
        let capturedText = try recognizedText(in: screenshot)
        XCTAssertTrue(capturedText.localizedCaseInsensitiveContains("Screen hidden"), capturedText)
        XCTAssertFalse(capturedText.localizedCaseInsensitiveContains("Synthetic sheet marker"))
        XCTAssertFalse(capturedText.localizedCaseInsensitiveContains("protein 42g"))

        // Swipe Notification Center away again; the sheet must be restored, not left behind the shield.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)))
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
