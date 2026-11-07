import XCTest

/// Temporary diagnostic for #930, not for merge: the clean-form edge swipe, repeated, with the screen state logged
/// around the drag so a failing pass says what was on screen.
final class EdgeSwipeRepeatDiagUITests: XCTestCase {
    private func state(_ app: XCUIApplication) -> String {
        let bars = app.navigationBars.allElementsBoundByIndex.map { $0.identifier }
        let typeIt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch.exists
        let sheets = app.sheets.count
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch.label
        return "bars=\(bars) typeIt=\(typeIt) sheets=\(sheets) tab=\(tab) windows=\(app.windows.count)"
    }

    func testRepeatedCleanFormEdgeSwipe() throws {
        let app = XCUIApplication()
        app.launch()
        addTeardownBlock { app.terminate() }
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }

        var failures = 0
        for pass in 1...8 {
            let candidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
            XCTAssertTrue(pollUntil(timeout: 20, { candidates.allElementsBoundByIndex.contains { $0.exists && $0.isHittable } }), "no Add button, pass \(pass)")
            candidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })?.tap()
            let typeIt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch
            XCTAssertTrue(typeIt.waitForExistence(timeout: 15), "no Type it in, pass \(pass)")
            print("EDGEDIAG pass \(pass) before type-it: \(state(app))")
            typeIt.tap()
            XCTAssertTrue(app.navigationBars["Log entry"].waitForExistence(timeout: 15), "no Log entry, pass \(pass)")
            let formBack = app.navigationBars["Log entry"].buttons["BackButton"]
            _ = pollUntil(timeout: 10, { formBack.exists && formBack.isHittable })
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            print("EDGEDIAG pass \(pass) before drag: \(state(app)) backHittable=\(formBack.exists && formBack.isHittable)")
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            var popped = typeIt.waitForExistence(timeout: 10)
            print("EDGEDIAG pass \(pass) after drag +10s: popped=\(popped) \(state(app))")
            if !popped {
                failures += 1
                // Recover to a known place: the form's Back.
                if formBack.exists && formBack.isHittable { formBack.tap() }
                popped = typeIt.waitForExistence(timeout: 10)
                print("EDGEDIAG pass \(pass) after Back: popped=\(popped) \(state(app))")
            }
            // Close the Add screen between passes.
            let cancel = app.buttons["Cancel"]
            if cancel.exists && cancel.isHittable { cancel.tap() }
            let close = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "Done")).firstMatch
            if close.exists && close.isHittable { close.tap() }
            _ = pollUntil(timeout: 5, { !app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Type it in")).firstMatch.exists })
            print("EDGEDIAG pass \(pass) after close: \(state(app))")
        }
        print("EDGEDIAG failures=\(failures) of 8")
        XCTAssertEqual(failures, 0, "the clean-form edge swipe failed \(failures) of 8 passes")
    }
}
