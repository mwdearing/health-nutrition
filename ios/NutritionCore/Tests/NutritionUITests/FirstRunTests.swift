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

/// Stands in for the app's Health connector. `access` is what Health reports now; a connect moves it to
/// `afterConnect` when that is set.
@MainActor
private final class HealthConnectorFake: AppleHealthConnecting {
    var access: AppleHealthAccess
    var afterConnect: AppleHealthAccess?
    private(set) var connectCalls = 0

    init(_ access: AppleHealthAccess) { self.access = access }

    func currentAccess() -> AppleHealthAccess { access }

    func connect() async {
        connectCalls += 1
        if let afterConnect { access = afterConnect }
    }
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

    private func logSupplement(_ store: JournalStore) throws {
        try store.create(
            Intake(
                id: UUID().uuidString.lowercased(), category: "food", occurredAt: when,
                timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "multi", name: "Daily multi", amount: 1, unit: .tablet)],
            product: ProductDefinition(
                snapshotID: "snap-multi", productID: "test", name: "Daily multi",
                labelBasis: "per serving (1 tablet)", catalogOrigin: "test", catalogVersion: "unknown",
                kind: .supplement, nutrients: [:]),
            now: when)
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
        XCTAssertEqual(preferences.unitSystem, DisplayPreferenceDefaults.unitSystem)
        XCTAssertEqual(preferences.quickWaterMilliliters, DisplayPreferenceDefaults.quickWaterMilliliters)
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
        XCTAssertEqual(memory.unitSystem, DisplayPreferenceDefaults.unitSystem)
        XCTAssertEqual(memory.quickWaterMilliliters, DisplayPreferenceDefaults.quickWaterMilliliters)
    }

    // MARK: - The checklist ticks off

    /// On an empty journal with no goals the card shows four items in order: three real ones not done
    /// and a placeholder. Each real item ticks off as its condition is met, and the card goes away when
    /// the first three are all done.
    func testChecklistTicksOffAsTheFirstDayGoesOn() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let preferences: DisplayPreferences & FirstRunPreferences = InMemoryDisplayPreferences()
        let health = HealthConnectorFake(AppleHealthAccess(undetermined: 3, authorized: 0, denied: 0))
        let model = FirstDayChecklistModel(
            store: journal, goals: goals, preferences: preferences,
            health: AppleHealthConnectionViewModel(connector: health))

        model.load()
        XCTAssertEqual(
            model.items.map(\.kind), [.logFirst, .setGoal, .chooseUnits, .connectHealth])
        XCTAssertEqual(
            model.items.map(\.title),
            ["Log your first food, drink, or supplement", "Set a daily goal", "Choose units", "Connect Apple Health"])
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

    func testSupplementOnlyJournalCompletesFirstIntakeChecklistItem() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let preferences: DisplayPreferences & FirstRunPreferences = InMemoryDisplayPreferences()
        let model = FirstDayChecklistModel(store: journal, goals: goals, preferences: preferences)

        try logSupplement(journal)
        model.load()

        XCTAssertEqual(model.items.first?.title, "Log your first food, drink, or supplement")
        XCTAssertEqual(model.items.first?.isDone, true)
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

    // MARK: - Connect Apple Health

    /// The Health step is done once Health is connected, and is not a placeholder any more.
    func testConnectHealthStepIsDoneWhenHealthIsConnected() throws {
        let health = HealthConnectorFake(AppleHealthAccess(undetermined: 0, authorized: 3, denied: 0))
        let model = FirstDayChecklistModel(
            store: try makeJournalStore(), goals: try makeGoalStore(),
            preferences: InMemoryDisplayPreferences(), health: AppleHealthConnectionViewModel(connector: health))

        model.load()
        let row = try XCTUnwrap(model.items.first { $0.kind == .connectHealth })
        XCTAssertEqual(row.title, "Connect Apple Health")
        XCTAssertTrue(row.isDone)
        XCTAssertFalse(row.isPlaceholder)
    }

    /// Until Health is connected the step is not done, and tapping it asks Health and then ticks off.
    func testConnectHealthStepCompletesAfterTheConnectAction() async throws {
        let health = HealthConnectorFake(AppleHealthAccess(undetermined: 3, authorized: 0, denied: 0))
        health.afterConnect = AppleHealthAccess(undetermined: 0, authorized: 3, denied: 0)
        let model = FirstDayChecklistModel(
            store: try makeJournalStore(), goals: try makeGoalStore(),
            preferences: InMemoryDisplayPreferences(), health: AppleHealthConnectionViewModel(connector: health))

        model.load()
        XCTAssertEqual(model.items.last?.isDone, false)
        await model.connectHealth()
        XCTAssertEqual(health.connectCalls, 1)
        XCTAssertEqual(model.items.last?.isDone, true)
    }

    /// A device with no Health gets no Health step at all, rather than a row that cannot be done.
    func testConnectHealthStepIsLeftOffWhenHealthIsUnavailable() throws {
        let health = HealthConnectorFake(.unavailable)
        let model = FirstDayChecklistModel(
            store: try makeJournalStore(), goals: try makeGoalStore(),
            preferences: InMemoryDisplayPreferences(), health: AppleHealthConnectionViewModel(connector: health))

        model.load()
        XCTAssertNil(model.items.first { $0.kind == .connectHealth })
        XCTAssertEqual(model.items.count, 3)
    }
}
