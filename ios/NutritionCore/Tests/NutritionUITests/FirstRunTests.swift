import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A defaults domain of this test's own, removed on teardown, so nothing here touches
/// `UserDefaults.standard`. The name is unique per call.
private func makeFirstRunSuite(_ label: String, _ teardown: XCTestCase) -> UserDefaults {
    let name = "healthnutrition.tests.firstrun.\(label).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        preconditionFailure("the test defaults suite \(name) could not be created")
    }
    defaults.removePersistentDomain(forName: name)
    teardown.addTeardownBlock {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
    return defaults
}

/// The first-run state: the welcome shown once, the first-day checklist and its Hide action.
@MainActor
final class FirstRunTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournalStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeGoalStore() throws -> SwiftDataGoalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
    }

    /// One synthetic entry, written the way the add flow writes one.
    private func logOats(_ store: JournalStore) throws {
        try store.create(
            Intake(
                id: UUID().uuidString.lowercased(), category: "food", occurredAt: when,
                timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Example oats", amount: 40, unit: .g)],
            product: nil, now: when)
    }

    // MARK: - The welcome is shown once

    /// A fresh install has not seen the welcome. Once it is marked seen, a later instance over the same
    /// defaults domain reads it as seen, and the value sits under the display prefix.
    func testWelcomeIsShownOnceAndTheFlagPersistsInTheDefaultsDomain() throws {
        let suite = makeFirstRunSuite("welcome-once", self)
        let first = UserDefaultsDisplayPreferences(defaults: suite)
        XCTAssertFalse(first.hasSeenWelcome)

        first.setHasSeenWelcome(true)
        let second = UserDefaultsDisplayPreferences(defaults: suite)
        XCTAssertTrue(second.hasSeenWelcome)
        XCTAssertTrue(suite.bool(forKey: "display.hasSeenWelcome"))
    }

    // MARK: - Erase clears the first-run flags

    /// The erase removes the welcome flag with the display settings, and removes every key the
    /// display preferences own from the defaults domain.
    func testEraseClearsTheWelcomeFlagInTheDefaultsStore() throws {
        let suite = makeFirstRunSuite("erase-defaults", self)
        let preferences = UserDefaultsDisplayPreferences(defaults: suite)
        preferences.setHasSeenWelcome(true)
        preferences.setChecklistHidden(true)
        preferences.setHasReviewedUnits(true)
        preferences.setUnitSystem(.usCustomary)
        preferences.setQuickWaterMilliliters(Decimal(300))

        preferences.resetToDefaults()

        XCTAssertFalse(preferences.hasSeenWelcome)
        XCTAssertFalse(preferences.isChecklistHidden)
        XCTAssertFalse(preferences.hasReviewedUnits)
        XCTAssertEqual(preferences.unitSystem, .metric)
        XCTAssertEqual(preferences.quickWaterMilliliters, Decimal(250))
        let leftover = suite.dictionaryRepresentation().keys.filter { $0.hasPrefix("display.") }
        XCTAssertEqual(leftover.sorted(), [])
    }

    /// The in-memory store follows the same rule: the three flags go back to false with the settings.
    func testEraseClearsTheWelcomeFlagInMemory() throws {
        let memory = InMemoryDisplayPreferences()
        memory.setHasSeenWelcome(true)
        memory.setChecklistHidden(true)
        memory.setHasReviewedUnits(true)
        memory.setUnitSystem(.usCustomary)
        memory.setQuickWaterMilliliters(Decimal(300))

        memory.resetToDefaults()

        XCTAssertFalse(memory.hasSeenWelcome)
        XCTAssertFalse(memory.isChecklistHidden)
        XCTAssertFalse(memory.hasReviewedUnits)
        XCTAssertEqual(memory.unitSystem, .metric)
        XCTAssertEqual(memory.quickWaterMilliliters, Decimal(250))
    }

    // MARK: - The checklist ticks off

    /// On an empty journal with no goals the card shows four items in order: three real ones not done
    /// and a placeholder. Each real item ticks off as its condition is met, and the card goes away when
    /// the first three are all done.
    func testChecklistTicksOffAsTheFirstDayGoesOn() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let preferences: DisplayPreferences & FirstRunPreferences = InMemoryDisplayPreferences()
        let model = FirstDayChecklistModel(store: journal, goals: goals, preferences: preferences)

        model.load()
        XCTAssertEqual(
            model.items.map(\.kind), [.logFirst, .setGoal, .chooseUnits, .connectHealth])
        XCTAssertEqual(
            model.items.map(\.title),
            ["Log your first food or drink", "Set a daily goal", "Choose units", "Connect Apple Health"])
        XCTAssertEqual(model.items.map(\.isDone), [false, false, false, false])
        XCTAssertEqual(model.items.map(\.isPlaceholder), [false, false, false, true])
        XCTAssertEqual(model.items[2].detail, "Metric")
        XCTAssertTrue(model.isVisible)

        try logOats(journal)
        model.load()
        XCTAssertEqual(model.items.map(\.isDone), [true, false, false, false])
        XCTAssertTrue(model.isVisible)

        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        model.load()
        XCTAssertEqual(model.items.map(\.isDone), [true, true, false, false])
        XCTAssertTrue(model.isVisible)

        model.markUnitsReviewed()
        XCTAssertEqual(model.items.map(\.isDone), [true, true, true, false])
        XCTAssertFalse(model.isVisible)
    }

    // MARK: - Hide stays hidden

    /// Hide removes the card now and the choice is stored, so a new model over the same preferences
    /// does not show the card again.
    func testChecklistHidesAndStaysHiddenOnANewModel() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let suite = makeFirstRunSuite("checklist-hide", self)
        let preferences: DisplayPreferences & FirstRunPreferences = UserDefaultsDisplayPreferences(defaults: suite)
        let model = FirstDayChecklistModel(store: journal, goals: goals, preferences: preferences)

        model.load()
        XCTAssertTrue(model.isVisible)
        model.hide()
        XCTAssertFalse(model.isVisible)
        XCTAssertTrue(preferences.isChecklistHidden)

        let rebuilt = FirstDayChecklistModel(store: journal, goals: goals, preferences: preferences)
        rebuilt.load()
        XCTAssertFalse(rebuilt.isVisible)
    }
}
