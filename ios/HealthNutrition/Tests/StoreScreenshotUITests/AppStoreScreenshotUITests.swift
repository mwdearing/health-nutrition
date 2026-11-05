import XCTest

/// Captures the App Store screenshots from the real app: it logs a few entries through the Add screens, then
/// saves a PNG of Today, Diary, Trends, Vitamins and minerals and Add, one file per screen, into the directory
/// named by SCREENSHOT_DIR. It runs only from the appstore-screenshots workflow (its own scheme), never in the
/// pull request gate, on a simulator set to light mode.
final class AppStoreScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? NSTemporaryDirectory() + "store-screenshots"
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launch()
        addTeardownBlock { self.app.terminate() }
    }

    // The steps run in name order on one install, so each builds on the data the one before it left. A step that
    // misses fails only itself; the capture step still saves whatever the app holds.

    func test1_SeedMeals() throws {
        try startOnToday()
        // Precondition: a fresh install with nothing logged, so the shots show only the seeded entries.
        XCTAssertFalse(
            app.staticTexts["Breakfast bowl"].exists, "the app already holds the demo entries; use a fresh simulator")

        try log("Breakfast bowl", meal: "Breakfast", calories: "420", protein: "24", carbs: "52", fat: "12")
        try log("Chicken and rice", meal: "Lunch", calories: "610", protein: "46", carbs: "62", fat: "17")
        try log("Greek yogurt and berries", meal: "Snack", calories: "190", protein: "17", carbs: "22", fat: "4")

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "no Cancel on the Add screen")
        cancel.tap()
        try goToToday()
    }

    /// Sets daily goals through the guided setup: maintain weight, then about, body and activity answers.
    func test2_SetGoals() throws {
        try startOnToday()
        let edit = app.buttons["Edit goals"]
        var scrolls = 0
        while !(edit.exists && edit.isHittable) && scrolls < 4 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(edit.exists && edit.isHittable, "no Edit goals link on Today")
        edit.tap()
        let help = app.buttons["Help me set my goals"]
        if !help.waitForExistence(timeout: 15) { debugFail("goals-screen", "no guided goal setup") }
        help.tap()

        try tapChoice("Maintain my weight")
        try next()
        try tapChoice("Female")
        try type("34", intoFieldStartingWith: "Age in years")
        dismissKeyboard()
        try next()
        try type("5", intoFieldStartingWith: "Height in feet")
        try type("9", intoFieldStartingWith: "Height in inches")
        try type("158", intoFieldStartingWith: "Weight in pounds")
        dismissKeyboard()
        try next()
        try tapChoice("Moderate exercise 3 to 5 days a week")
        try next()
        let save = app.buttons["Save goals"]
        var saveScrolls = 0
        while !(save.exists && save.isHittable) && saveScrolls < 4 {
            app.swipeUp()
            saveScrolls += 1
        }
        XCTAssertTrue(save.exists && save.isHittable, "no Save goals on the results step")
        save.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "Settings did not come back after saving the goals")
        done.tap()
        try goToToday()
    }

    /// Logs water with the quick button on Today.
    func test3_LogWater() throws {
        try startOnToday()
        let water = app.buttons["Add 8 fluid ounces of water"]
        var scrolls = 0
        while !(water.exists && water.isHittable) && scrolls < 4 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(water.exists && water.isHittable, "no quick water button on Today")
        for _ in 0..<3 {
            water.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    /// Logs a few entries on the days before, through the When date control, so Trends and the week have history.
    func test4_History() throws {
        try startOnToday()
        try log("Oatmeal with banana", meal: "Breakfast", calories: "350", protein: "12", carbs: "62", fat: "7", daysAgo: 1)
        try log("Turkey sandwich", meal: "Lunch", calories: "520", protein: "34", carbs: "48", fat: "16", daysAgo: 1)
        try log("Salmon and vegetables", meal: "Dinner", calories: "640", protein: "42", carbs: "30", fat: "28", daysAgo: 2)
        try log("Pasta and salad", meal: "Dinner", calories: "710", protein: "25", carbs: "96", fat: "22", daysAgo: 3)
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 10) { cancel.tap() }
    }

    func test9_CaptureTheStoreScreens() throws {
        try startOnToday()
        let hideChecklist = app.buttons["Hide checklist"]
        if hideChecklist.waitForExistence(timeout: 3) { hideChecklist.tap() }
        capture("1-today")

        tapTab("Diary")
        let day = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", "(?s).*1.?220.*")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 15), "the Diary does not show the seeded day total")
        capture("2-diary")

        tapTab("Trends")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Insights")).firstMatch.waitForExistence(timeout: 15),
            "the Trends screen did not load")
        capture("3-trends")

        try goToToday()
        let gaps = app.buttons["Vitamins and minerals"]
        if !gaps.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(gaps.waitForExistence(timeout: 10), "no Vitamins and minerals link on Today")
        gaps.tap()
        XCTAssertTrue(app.navigationBars["Vitamins and minerals"].waitForExistence(timeout: 15))
        capture("4-nutrients")
        app.navigationBars.buttons.firstMatch.tap()

        try goToToday()
        let add = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        XCTAssertTrue(pollUntil(timeout: 30, { add.allElementsBoundByIndex.contains { $0.exists && $0.isHittable } }))
        add.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })?.tap()
        XCTAssertTrue(app.navigationBars["Add"].waitForExistence(timeout: 15), "the Add screen did not open")
        capture("5-add")
    }

    // MARK: - Steps shared by the tests

    /// Sets the entry's day to `daysAgo` days back with the When date control: the date pill opens a calendar and
    /// the day is picked by its name.
    private func chooseDay(daysAgo: Int) throws {
        dismissKeyboard()
        let target = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d"
        let dayName = formatter.string(from: target)
        var scrolls = 0
        let picker = app.datePickers.firstMatch
        while !(picker.exists && picker.isHittable) && scrolls < 4 {
            app.swipeUp()
            scrolls += 1
        }
        guard picker.exists else { debugFail("no-when-picker", "no When date control"); return }
        let dateButton = picker.buttons.firstMatch
        guard dateButton.exists else { debugFail("no-when-button", "no date button in the When control"); return }
        dateButton.tap()
        let day = app.buttons[dayName]
        if !day.waitForExistence(timeout: 5) { debugFail("no-day-\(daysAgo)", "no calendar day named \(dayName)"); return }
        day.tap()
        // A tap outside the calendar closes it.
        app.tap()
    }

    /// Keeps a shot and the element tree under debug/, then fails the step.
    private func debugFail(_ name: String, _ message: String) {
        capture("debug-\(name)")
        try? app.debugDescription.write(to: outputFile("debug-tree-\(name)", ext: "txt"), atomically: true, encoding: .utf8)
        XCTFail(message)
    }

    private func startOnToday() throws {
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        XCTAssertTrue(element("todayDate").waitForExistence(timeout: 30), "the Today screen did not appear")
    }

    private func tapChoice(_ title: String) throws {
        let choice = app.buttons[title]
        var scrolls = 0
        while !(choice.exists && choice.isHittable) && scrolls < 4 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(choice.exists && choice.isHittable, "no choice named \(title)")
        choice.tap()
    }

    private func next() throws {
        let next = app.buttons["Next"]
        XCTAssertTrue(pollUntil(timeout: 10, { next.exists && next.isHittable && next.isEnabled }), "Next is not available")
        next.tap()
    }

    // MARK: - Seeding

    /// Logs one entry through Add, "Amounts only". After a Log the Add screen stays open (its Recent list now holds
    /// the entry), so the next entry starts from there; the first one opens Add from Today.
    private func log(
        _ name: String, meal: String, calories: String, protein: String, carbs: String, fat: String, daysAgo: Int = 0
    ) throws {
        if !app.buttons["Amounts only"].exists {
            let add = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
            if !pollUntil(timeout: 30, { add.allElementsBoundByIndex.contains { $0.exists && $0.isHittable } }) {
                capture("debug-no-add-before-\(name)")
                XCTFail("no hittable Add button")
            }
            add.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })?.tap()
        }
        let amountsOnly = app.buttons["Amounts only"]
        XCTAssertTrue(amountsOnly.waitForExistence(timeout: 20), "no Amounts only action on Add")
        chooseMealOnAddHome(meal, entry: name)
        // The meal menu is still closing for a moment, so the action is tapped once it is hittable again.
        var scrolls = 0
        while !pollUntil(timeout: 5, { amountsOnly.exists && amountsOnly.isHittable }) && scrolls < 3 {
            app.swipeUp()
            scrolls += 1
        }
        if !(amountsOnly.exists && amountsOnly.isHittable) {
            capture("debug-amounts-only-not-tappable-\(name)")
            try? app.debugDescription.write(
                to: outputFile("debug-tree-amounts-only-\(name)", ext: "txt"), atomically: true,
                encoding: .utf8)
            XCTFail("Amounts only is not tappable")
        }
        amountsOnly.tap()
        XCTAssertTrue(app.navigationBars["Amounts only"].waitForExistence(timeout: 15))

        try type(calories, intoFieldStartingWith: "Calories")
        try type(protein, intoFieldStartingWith: "Protein")
        try type(carbs, intoFieldStartingWith: "Carbs")
        try type(name, intoFieldStartingWith: "Name")
        if daysAgo > 0 { try chooseDay(daysAgo: daysAgo) }

        let logButton = app.buttons["Log"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 10), "no Log button")
        dismissKeyboard()
        XCTAssertTrue(logButton.isEnabled, "Log is disabled after the amounts were typed")
        logButton.tap()
        XCTAssertTrue(
            pollUntil(timeout: 20, { !self.app.navigationBars["Amounts only"].exists }), "the sheet did not close after Log")
        XCTAssertTrue(
            app.buttons["Amounts only"].waitForExistence(timeout: 20), "the Add screen did not come back after Log")
    }

    private func type(_ text: String, intoFieldStartingWith prefix: String) throws {
        let field = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@ OR identifier BEGINSWITH %@", prefix, prefix))
            .firstMatch
        // The keyboard and the Log bar cover the lower fields, so the keyboard goes down and the form scrolls
        // until the field sits clear of the bottom bar before it is tapped.
        dismissKeyboard()
        let screenHeight = app.windows.firstMatch.frame.height
        var scrolls = 0
        while !(field.exists && field.isHittable && field.frame.maxY < screenHeight * 0.75) && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field named \(prefix)")
        // A tap that lands while the sheet is still sliding up is lost, so it is repeated while no keyboard shows.
        var attempts = 0
        repeat {
            field.tap()
            attempts += 1
        } while !pollUntil(timeout: 3, { self.app.keyboards.count > 0 }) && attempts < 4
        if !pollUntil(timeout: 10, { self.app.keyboards.count > 0 }) {
            capture("debug-\(prefix)-no-focus")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("the \(prefix) field did not take focus (field frame \(field.frame))")
        }
        app.typeText(text)
    }

    /// Sets the meal on the Add screen's meal menu, which the next entry takes. A miss fails the test, because the
    /// entry would land under Other and the store shot would show the wrong meal.
    private func chooseMealOnAddHome(_ meal: String, entry: String) {
        let menu = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label == %@", "meal", "None")).firstMatch
        guard menu.waitForExistence(timeout: 5), menu.isHittable else {
            try? app.debugDescription.write(
                to: outputFile("debug-tree-no-meal-menu-\(entry)", ext: "txt"), atomically: true,
                encoding: .utf8)
            XCTFail("no meal menu on the Add screen for \(entry)")
            return
        }
        menu.tap()
        let option = app.buttons[meal]
        if option.waitForExistence(timeout: 5) {
            option.tap()
            // The menu now names the chosen meal; a miss would put the entry under Other in the shots.
            let chosen = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", meal)).firstMatch
            XCTAssertTrue(chosen.waitForExistence(timeout: 5), "the meal menu did not take \(meal)")
        } else {
            XCTFail("no \(meal) option in the meal menu")
            capture("debug-meal-menu-\(entry)")
            try? app.debugDescription.write(
                to: outputFile("debug-tree-meal-menu-\(entry)", ext: "txt"), atomically: true,
                encoding: .utf8)
        }
    }

    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() } else { app.navigationBars.staticTexts.firstMatch.tap() }
        _ = pollUntil(timeout: 5, { self.app.keyboards.count == 0 })
    }

    // MARK: - Navigation and capture

    private func goToToday() throws {
        tapTab("Today")
        XCTAssertTrue(element("todayDate").waitForExistence(timeout: 15), "Today did not appear")
    }

    private func tapTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no \(name) tab")
        tab.tap()
    }

    private func capture(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = outputFile(name, ext: "png")
        do { try screenshot.pngRepresentation.write(to: url) } catch { XCTFail("could not write \(url.path): \(error)") }
    }

    /// Store shots go in the output directory; debug shots and trees go in its `debug` folder, which is uploaded
    /// separately and only on failure, so they never join the store set.
    private func outputFile(_ name: String, ext: String) -> URL {
        let isDebug = name.hasPrefix("debug")
        let directory = isDebug ? outputDirectory.appendingPathComponent("debug", isDirectory: true) : outputDirectory!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(name).\(ext)")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

/// Polls `condition` until it holds or `timeout` seconds pass; true when it held.
private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
}
