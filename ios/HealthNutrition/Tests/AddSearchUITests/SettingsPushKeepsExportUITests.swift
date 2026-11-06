import XCTest

/// Settings keeps the exported file while a screen is pushed over it. The form disappears when Privacy or Daily goals
/// is pushed, and an earlier version of the form deleted the export then, so coming back showed no Share button.
final class SettingsPushKeepsExportUITests: XCTestCase {
    /// Launches the app, opens Settings from Today (Edit goals pushes Daily goals first, so the person goes back to the
    /// form), makes an export, and returns the app with the Share button on screen.
    private func appWithAnExport() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }

        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        let edit = app.buttons["Edit goals"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15), "no Edit goals button on Today")
        edit.tap()

        // Edit goals opens Settings with Daily goals already pushed; go back to the form itself.
        let form = app.buttons["Export journal"]
        if !form.waitForExistence(timeout: 5) { goBack(in: app) }
        scrollTo(form, in: app)
        XCTAssertTrue(form.exists, "no Export journal button in Settings\n\(app.debugDescription)")
        form.tap()

        let share = shareButton(in: app)
        scrollTo(share, in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 15), "no Share the export button after exporting\n\(app.debugDescription)")
        return app
    }

    private func shareButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Share the export"]
    }

    /// Taps the back button of the pushed screen (the first button in the navigation bar).
    private func goBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button on the pushed screen")
        back.tap()
    }

    /// A form builds the rows near the screen, so a row below the fold is scrolled into view.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.waitForExistence(timeout: 2), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }

    func testOpeningDailyGoalsKeepsTheExport() throws {
        let app = try appWithAnExport()

        // The Daily goals row sits at the top of the form.
        for _ in 0..<8 where !app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Daily goals")).firstMatch.isHittable {
            app.swipeDown()
        }
        let goals = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Daily goals")).firstMatch
        XCTAssertTrue(goals.waitForExistence(timeout: 10), "no Daily goals row in Settings")
        goals.tap()
        goBack(in: app)

        let share = shareButton(in: app)
        scrollTo(share, in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 10),
                      "the export was deleted when Daily goals was pushed\n\(app.debugDescription)")
    }

    func testOpeningPrivacyKeepsTheExport() throws {
        let app = try appWithAnExport()

        let privacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Your journal stays on this device")).firstMatch
        scrollTo(privacy, in: app)
        for _ in 0..<8 where !privacy.isHittable { app.swipeUp() }
        XCTAssertTrue(privacy.waitForExistence(timeout: 10), "no Privacy row in Settings")
        privacy.tap()
        goBack(in: app)

        let share = shareButton(in: app)
        scrollTo(share, in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 10),
                      "the export was deleted when Privacy was pushed\n\(app.debugDescription)")
    }
}
