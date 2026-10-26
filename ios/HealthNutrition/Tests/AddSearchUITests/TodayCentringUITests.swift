import XCTest

/// The Today header (title and date) and the Food row are centred on the screen. Measured with the on-screen frames
/// XCUITest reports, on an empty Today, so it checks the layout the person sees without needing any goal saved.
final class TodayCentringUITests: XCTestCase {
    /// Points allowed between the centre of an element and the centre of the window.
    private let tolerance: CGFloat = 1

    func testTheTitleDateAndFoodRowAreCentredOnTheScreen() throws {
        let app = launchToToday()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window")
        let windowMidX = window.frame.midX

        for identifier in ["todayHeader", "todayDate", "calorieFoodBurnedRow"] {
            let element = element(identifier, in: app)
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) is not on screen")
            let midX = element.frame.midX
            XCTAssertEqual(
                midX, windowMidX, accuracy: tolerance,
                "\(identifier) midX \(midX) is not within \(tolerance) pt of the window midX \(windowMidX)")
        }
    }

    /// The screen keeps its name for VoiceOver and the back button, even though the bar draws no visible title.
    func testTheScreenNameIsStillTheNavigationTitle() throws {
        let app = launchToToday()
        let bar = app.navigationBars["Today"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the navigation bar has no screen name 'Today' for VoiceOver")
    }

    /// The visual Today title is hidden from VoiceOver, so the navigation title is the one spoken "Today".
    func testTheTodayTitleIsNotReadTwice() throws {
        let app = launchToToday()
        // The navigation bar and the tab bar carry their own "Today". The screen content, which is the scroll view,
        // must not repeat it: the in-content heading is hidden from accessibility.
        let today = NSPredicate(format: "label == %@", "Today")
        let inContent = app.scrollViews.staticTexts.matching(today).count
        XCTAssertEqual(
            inContent, 0,
            "the Today title is read \(inContent) more time(s) inside the screen content")
    }

    /// Launches the app, dismisses onboarding if it shows, and waits for the Today screen's date line.
    private func launchToToday() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // Registered on launch, so the app terminates after the test's own teardown.
        addTeardownBlock { app.terminate() }
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        XCTAssertTrue(element("todayDate", in: app).waitForExistence(timeout: 15), "the Today screen did not appear")
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
