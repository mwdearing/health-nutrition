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

        // Edit goals may open Settings with Daily goals already pushed. The form is the screen whose navigation bar is
        // titled Settings, so when it is not showing the person goes back to it.
        let settings = app.navigationBars["Settings"]
        _ = settings.waitForExistence(timeout: 15)
        // While Daily goals is pushed over the form, its bar is on screen; the form's bar may still be in the tree.
        if app.navigationBars["Daily goals"].waitForExistence(timeout: 3) { goBack(from: "Daily goals", in: app) }
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the Settings form is not showing\n\(app.debugDescription)")

        let export = app.buttons["Export journal"]
        scroll(to: export, in: app, down: true)
        XCTAssertTrue(export.exists, "no Export journal button in Settings\n\(app.debugDescription)")
        export.tap()

        let share = shareButton(in: app)
        scroll(to: share, in: app, down: true)
        XCTAssertTrue(share.waitForExistence(timeout: 15), "no Share the export button after exporting\n\(app.debugDescription)")
        return app
    }

    private func shareButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Share the export"]
    }

    /// Waits for the pushed screen's navigation bar, titled `title`, and taps its back button: the bar's first button that
    /// is not Done (the pushed screen carries the sheet's Done too). A push that did not happen fails here, with the
    /// sheet still open, rather than dismissing Settings.
    private func goBack(from title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "\(title) is not showing\n\(app.debugDescription)")
        let back = bar.buttons.matching(NSPredicate(format: "label != %@", "Done")).element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button on \(title)")
        back.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "\(title) is still showing after going back\n\(app.debugDescription)")
    }

    /// A form builds the rows near the screen, so a row off screen is scrolled into view: `down` reveals rows below the
    /// ones showing, otherwise rows above them. Stops as soon as the element is hittable.
    private func scroll(to element: XCUIElement, in app: XCUIApplication, down: Bool) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 10 {
            if down { app.swipeUp() } else { app.swipeDown() }
            swipes += 1
        }
    }

    func testOpeningDailyGoalsKeepsTheExport() throws {
        let app = try appWithAnExport()

        // The Daily goals row sits at the top of the form, above the export rows.
        let goals = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Daily goals")).firstMatch
        scroll(to: goals, in: app, down: false)
        XCTAssertTrue(goals.exists && goals.isHittable, "no Daily goals row in Settings\n\(app.debugDescription)")
        goals.tap()
        goBack(from: "Daily goals", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "did not return to the Settings form")

        let share = shareButton(in: app)
        scroll(to: share, in: app, down: true)
        XCTAssertTrue(share.waitForExistence(timeout: 10) && share.isHittable,
                      "the export was deleted when Daily goals was pushed\n\(app.debugDescription)")
    }

    func testOpeningPrivacyKeepsTheExport() throws {
        let app = try appWithAnExport()

        // The Privacy row sits above the export rows.
        let privacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Your journal stays on this device")).firstMatch
        scroll(to: privacy, in: app, down: false)
        XCTAssertTrue(privacy.exists && privacy.isHittable, "no Privacy row in Settings\n\(app.debugDescription)")
        privacy.tap()
        goBack(from: "Privacy", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "did not return to the Settings form")

        let share = shareButton(in: app)
        scroll(to: share, in: app, down: true)
        XCTAssertTrue(share.waitForExistence(timeout: 10) && share.isHittable,
                      "the export was deleted when Privacy was pushed\n\(app.debugDescription)")
    }
}
