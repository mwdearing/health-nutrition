import XCTest
import Vision

final class PrivacyShieldUITests: XCTestCase {
    func testSyntheticSheetIsShieldedInAppSwitcherAndRestoredOnReturn() throws {
        let app = launchPrivacyFixture()
        app.buttons["Show synthetic sheet"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        openAppSwitcher(in: springboard)
        let screenshot = XCUIScreen.main.screenshot()
        attach(screenshot, named: "privacy-shield-app-switcher-synthetic-sheet")
        let capturedText = try recognizedText(in: screenshot)
        XCTAssertTrue(capturedText.localizedCaseInsensitiveContains("Screen hidden"), capturedText)
        XCTAssertFalse(capturedText.localizedCaseInsensitiveContains("Synthetic sheet marker"))
        XCTAssertFalse(capturedText.localizedCaseInsensitiveContains("protein 42g"))

        app.activate()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["synthetic-entry-marker"].exists)
    }

    func testSyntheticSignInAndCaptchaReturnDoesNotLeaveShieldStuck() {
        let app = launchPrivacyFixture()
        app.buttons["show-auth-return-fixture"].tap()
        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.staticTexts["synthetic-sheet-marker"].waitForExistence(timeout: 5))
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
        // A card label is the guard that the captured frame is the app switcher, not just SpringBoard.
        let appCard = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "HealthNutrition"))
            .firstMatch
        XCTAssertTrue(appCard.waitForExistence(timeout: 5), springboard.debugDescription)
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
