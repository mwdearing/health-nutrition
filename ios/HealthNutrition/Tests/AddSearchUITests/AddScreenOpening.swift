import XCTest

/// Opens the Add screen from Today and returns whether `marker`, an element only the Add screen has, appeared.
///
/// Two buttons share the Add label and the first is not hittable, so the hittable one is tapped, after waiting
/// up to 30 s because a slow runner can take most of a minute to settle after launch. A tap that lands while Today
/// is still settling leaves Today on screen, so the tap is checked by `marker` appearing, with one more tap only
/// while Today's Add button is still hittable and `marker` is still absent, so an Add screen that opened late is
/// not opened a second time. Shared by the Add UI tests that start from Today.
@discardableResult
func openAddScreen(
    in app: XCUIApplication, until marker: XCUIElement, file: StaticString = #filePath, line: UInt = #line
) -> Bool {
    let addCandidates = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
    func hittableAdd() -> XCUIElement? {
        addCandidates.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
    }
    XCTAssertTrue(
        pollUntil(timeout: 30, { hittableAdd() != nil }), "no hittable Add button on the Today screen",
        file: file, line: line)
    hittableAdd()?.tap()
    if !marker.waitForExistence(timeout: 10), !marker.exists, let add = hittableAdd() { add.tap() }
    return marker.waitForExistence(timeout: 20)
}

/// Polls `condition` until it holds or `timeout` seconds pass; true when it held.
func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
}
