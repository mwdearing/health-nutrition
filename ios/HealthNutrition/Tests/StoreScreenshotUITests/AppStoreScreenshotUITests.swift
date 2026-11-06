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
        let goalsRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Daily goals")).firstMatch
        if !goalsRow.waitForExistence(timeout: 15) { debugFail("settings-screen", "no Daily goals row in Settings") }
        goalsRow.tap()
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
        // Saving closes the guided setup and leaves the Goals screen, one step inside Settings.
        let done = app.buttons["Done"]
        if !done.waitForExistence(timeout: 5) {
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 10) { back.tap() }
        }
        if !done.waitForExistence(timeout: 15) { debugFail("after-goals-save", "Settings did not come back after saving the goals") }
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

    /// Makes a supplement product with vitamin and mineral facts through Create product. This step is being
    /// built against the real screens: each step keeps a shot and the element tree when it cannot continue.
    func test5_Supplement() throws {
        try startOnToday()
        try openAddHome()
        let create = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Create product")).firstMatch
        if !create.waitForExistence(timeout: 10) { debugFail("no-create-product", "no Create product on Add") }
        var scrolls = 0
        while !(create.exists && create.isHittable) && scrolls < 4 {
            app.swipeUp()
            scrolls += 1
        }
        create.tap()
        XCTAssertTrue(app.navigationBars["Product editor"].waitForExistence(timeout: 15), "the product editor did not open")
        try type("Daily multivitamin", intoFieldStartingWith: "Name")
        dismissKeyboard()
        try choose("Kind", option: "Supplement")
        try choose("Facts are stated", option: "Per serving")
        // Saving checks the serving, so a quantity is stated (the unit stays "serving").
        try type("1", intoFieldStartingWith: "Product serving quantity")
        dismissKeyboard()
        // The first fact's menu opens tall, so its deep entry (Vitamin D) is reachable; later rows raise a keyboard that
        // cuts the menu off, so they take entries near its top.
        try addFact(nutrient: "Vitamin D", amount: "20", unit: "mcg")
        try addFact(nutrient: "Calcium", amount: "200", unit: "mg")
        let save = app.buttons["Save product on this device"]
        var saveScrolls = 0
        while !(save.exists && save.isHittable) && saveScrolls < 6 {
            app.swipeUp()
            saveScrolls += 1
        }
        if !(save.exists && save.isHittable) { debugFail("no-save-product", "no Save product button"); return }
        save.tap()
        if !pollUntil(timeout: 15, { !self.app.navigationBars["Product editor"].exists }) {
            debugFail("after-save-product", "the product editor did not close after saving")
            return
        }
        // The product now lives in the Library; this step is being built against the real screens.
        try openAddHome()
        let fromLibrary = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "From Library")).firstMatch
        if !fromLibrary.waitForExistence(timeout: 10) { debugFail("no-from-library", "no From Library on Add"); return }
        var libScrolls = 0
        while !(fromLibrary.exists && fromLibrary.isHittable) && libScrolls < 4 {
            app.swipeUp()
            libScrolls += 1
        }
        fromLibrary.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        debugFail("library-picker", "learning the Library picker")
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
        // Trends opens on a list of two reports; the shot is the Insights report, which holds the week's logging
        // and the averages.
        let insights = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Insights")).firstMatch
        insights.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "days logged")).firstMatch.waitForExistence(timeout: 15),
            "the Insights report did not load")
        capture("3-trends")
        app.navigationBars.buttons.firstMatch.tap()

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
        // A tap outside the calendar closes it; the form is touched again only once the calendar is gone, because a
        // tap that lands while it closes is swallowed.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        _ = pollUntil(timeout: 10, { !day.exists })
        RunLoop.current.run(until: Date().addingTimeInterval(1))
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

    /// Adds one stated fact to the product editor: the new row is the last one, so its menus are the last matches.
    private func addFact(nutrient: String, amount: String, unit: String) throws {
        let addFact = app.buttons["Add fact"]
        var scrolls = 0
        while !(addFact.exists && addFact.isHittable) && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        if !(addFact.exists && addFact.isHittable) { debugFail("no-add-fact-\(nutrient)", "no Add fact button"); return }
        addFact.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try pickInLastRow("Nutrient", option: nutrient)
        try pickInLastRow("Fact state", option: "Known amount")
        let amountFields = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Amount"))
        if !pollUntil(timeout: 10, { amountFields.count > 0 }) { debugFail("no-amount-\(nutrient)", "no Amount field for \(nutrient)"); return }
        let amountField = amountFields.allElementsBoundByIndex.last!
        var fieldScrolls = 0
        while !amountField.isHittable && fieldScrolls < 6 {
            app.swipeUp()
            fieldScrolls += 1
        }
        amountField.tap()
        if !pollUntil(timeout: 5, { self.app.keyboards.count > 0 }) { debugFail("amount-no-focus-\(nutrient)", "the Amount field did not take focus"); return }
        app.typeText(amount)
        dismissKeyboard()
        try pickInLastRow("Fact unit", option: unit)
    }

    /// Picks `option` in the menu whose label starts with `title`, taking the last such menu on screen.
    private func pickInLastRow(_ title: String, option: String) throws {
        let menus = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
        if !pollUntil(timeout: 10, { menus.count > 0 }) { debugFail("no-row-menu-\(title)", "no \(title) menu"); return }
        let menu = menus.allElementsBoundByIndex.last!
        var scrolls = 0
        while !menu.isHittable && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        // A new fact row can take focus in its display name, which raises a keyboard over the menu, so the keyboard is
        // put down first, more than once if needed.
        var tries = 0
        while app.keyboards.count > 0 && tries < 3 {
            dismissKeyboard()
            tries += 1
        }
        menu.tap()
        let choice = app.buttons[option]
        // A long menu lists only the rows near the top until it is scrolled, so it is dragged up until the option
        // shows (a swipe on the app can miss the menu, so the drag starts inside it).
        // The menu takes a moment to open, and a drag that starts before then would close it again.
        _ = pollUntil(timeout: 4, { choice.exists && choice.isHittable })
        var menuScrolls = 0
        while !(choice.exists && choice.isHittable) && menuScrolls < 10 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3))
            from.press(forDuration: 0.1, thenDragTo: to)
            menuScrolls += 1
        }
        if !(choice.exists && choice.isHittable) {
            debugFail("no-row-option-\(title)-\(option)", "no \(option) in the \(title) menu")
            return
        }
        choice.tap()
    }

    private func openAddHome() throws {
        if app.buttons["Amounts only"].exists { return }
        let add = app.buttons.matching(NSPredicate(format: "label == %@", "Add food, drink, or supplement"))
        XCTAssertTrue(
            pollUntil(timeout: 30, { add.allElementsBoundByIndex.contains { $0.exists && $0.isHittable } }),
            "no hittable Add button")
        add.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })?.tap()
        XCTAssertTrue(app.buttons["Amounts only"].waitForExistence(timeout: 20), "the Add screen did not open")
    }

    /// Picks `option` in the menu picker whose label starts with `title`.
    private func choose(_ title: String, option: String) throws {
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        var scrolls = 0
        while !(menu.exists && menu.isHittable) && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        if !(menu.exists && menu.isHittable) { debugFail("no-menu-\(title)", "no \(title) menu"); return }
        menu.tap()
        let choice = app.buttons[option]
        if !choice.waitForExistence(timeout: 5) { debugFail("no-option-\(title)", "no \(option) in the \(title) menu"); return }
        choice.tap()
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
        // One more tap if the first was swallowed while a popover was closing.
        if !pollUntil(timeout: 6, { !self.app.navigationBars["Amounts only"].exists }), logButton.exists, logButton.isHittable {
            logButton.tap()
        }
        if !pollUntil(timeout: 20, { !self.app.navigationBars["Amounts only"].exists }) {
            debugFail("log-did-not-close-\(name)", "the sheet did not close after Log")
        }
        XCTAssertTrue(
            app.buttons["Amounts only"].waitForExistence(timeout: 20), "the Add screen did not come back after Log")
    }

    private func type(_ text: String, intoFieldStartingWith prefix: String, required: Bool = true) throws {
        // Some fields carry only a placeholder (the product editor's), so the placeholder is matched too.
        let field = app.textFields.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR identifier BEGINSWITH %@ OR placeholderValue BEGINSWITH %@", prefix, prefix, prefix))
            .firstMatch
        // A field above the fold is reached by scrolling back up first.
        var upScrolls = 0
        while !field.exists && upScrolls < 3 {
            app.swipeDown()
            upScrolls += 1
        }
        // The keyboard and the Log bar cover the lower fields, so the keyboard goes down and the form scrolls
        // until the field sits clear of the bottom bar before it is tapped.
        dismissKeyboard()
        let screenHeight = app.windows.firstMatch.frame.height
        var scrolls = 0
        while !(field.exists && field.isHittable && field.frame.maxY < screenHeight * 0.75) && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        if !field.waitForExistence(timeout: 10) {
            if required { debugFail("no-field-\(prefix)", "no field named \(prefix)") }
            return
        }
        // A tap that lands while the sheet is still sliding up is lost, so it is repeated while no keyboard shows.
        var attempts = 0
        repeat {
            field.tap()
            attempts += 1
        } while !pollUntil(timeout: 3, { self.app.keyboards.count > 0 }) && attempts < 4
        if !pollUntil(timeout: 10, { self.app.keyboards.count > 0 }) {
            if !required { return }
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
        // With entries in Recent the Add screen can open scrolled; the meal menu is at its top.
        var upScrolls = 0
        while !(menu.exists && menu.isHittable) && upScrolls < 3 {
            app.swipeDown()
            upScrolls += 1
        }
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
        // The number pads put a Done in the toolbar (more than one element can carry it), so the first one that can
        // be tapped is used; a title tap is the fallback.
        // Only a Done in the lower half belongs to the keyboard; the Settings sheet's own Done is at the top.
        let lowerHalf = app.windows.firstMatch.frame.height * 0.4
        if let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex
            .first(where: { $0.exists && $0.isHittable && $0.frame.minY > lowerHalf })
        {
            done.tap()
        } else if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        } else {
            app.navigationBars.staticTexts.firstMatch.tap()
        }
        if !pollUntil(timeout: 3, { self.app.keyboards.count == 0 }) {
            // Dragging the keyboard down closes it the way a person would.
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
            from.press(forDuration: 0.1, thenDragTo: to)
            _ = pollUntil(timeout: 3, { self.app.keyboards.count == 0 })
        }
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
