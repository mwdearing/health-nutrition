import Foundation
import NutritionDomain
import NutritionJournal
import NutritionUI
import XCTest

@testable import HealthNutrition

/// The app's own wiring, read from inside the app target.
///
/// These build a whole `AppServices` on throwaway files and run the erase the Connections and privacy
/// screen offers, so the three stores are checked as the app wires them rather than one at a time: an
/// erase that emptied the journal but left the recipes behind would still look like a working erase on
/// any single store.
@MainActor
final class AppServicesEraseTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let intakeID = "3f5a1c72-8d64-4b19-9e0a-2c7f6b4d8e51"

    /// A fresh directory per test, so a store file one test wrote can never be read by another and no
    /// test touches the app's real Application Support files.
    private func makeServices() throws -> (AppServices, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler()), directory)
    }

    private func sampleIntake() -> Intake {
        Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast")
    }

    private func oats() -> IntakeComponent {
        IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 40, unit: .g)
    }

    private func sampleFavorite() -> FavoriteTemplate {
        FavoriteTemplate(
            id: "favorite-oats", displayName: "Oat porridge", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "40", unitSymbol: "g")])
    }

    private func sampleRecipe() -> RecipeVersion {
        RecipeVersion(
            recipeID: "recipe-oats", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour",
                    quantity: Quantity(value: Decimal(string: "200")!, unit: .g),
                    perUnit: ["energy": .known(Decimal(string: "3.6")!, .kcal)])
            ],
            yield: .servings(4), createdAt: when)
    }

    private func sampleGoal() -> NutrientGoal {
        NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)
    }

    /// One journal entry, one favorite, one recipe and one daily goal, so the erase below has
    /// something in every store the app keeps.
    private func fill(_ services: AppServices) throws {
        try services.journalStore.create(sampleIntake(), components: [oats()], product: nil, now: when)
        try services.favoritesStore.add(sampleFavorite())
        try services.recipeStore.saveNewVersion(sampleRecipe())
        try services.goalStore.setGoal(sampleGoal())
    }

    /// The erase empties the journal, the favorites, the recipes and the daily goals: every store
    /// the app keeps holds nothing afterwards, and the screen reports that it worked rather than
    /// leaving a person to believe data was deleted when it was not.
    func testEraseEmptiesTheJournalTheFavoritesTheRecipesAndTheGoals() throws {
        let (services, _) = try makeServices()
        try fill(services)

        let erased = services.connections.eraseAllData()

        XCTAssertTrue(erased)
        XCTAssertNil(services.connections.errorMessage)
        XCTAssertTrue(try services.journalStore.activeIntakes().isEmpty)
        XCTAssertTrue(try services.favoritesStore.list().isEmpty)
        XCTAssertTrue(try services.recipeStore.list().recipes.isEmpty)
        XCTAssertTrue(try services.goalStore.goals().isEmpty)
    }

    /// An erase is a new start rather than a broken store: the same store instances take a write
    /// afterwards and the entry is readable again.
    func testTheStoresStayUsableAfterAnErase() throws {
        let (services, _) = try makeServices()
        try fill(services)
        XCTAssertTrue(services.connections.eraseAllData())

        try services.journalStore.create(sampleIntake(), components: [oats()], product: nil, now: when)
        try services.favoritesStore.add(sampleFavorite())
        try services.recipeStore.saveNewVersion(sampleRecipe())
        try services.goalStore.setGoal(sampleGoal())

        XCTAssertEqual(try services.journalStore.activeIntakes().map(\.id), [intakeID])
        XCTAssertEqual(try services.favoritesStore.list().map(\.id), ["favorite-oats"])
        XCTAssertEqual(try services.recipeStore.list().recipes.map(\.recipeID), ["recipe-oats"])
        XCTAssertEqual(try services.goalStore.goals().map(\.nutrient), ["protein"])
    }

    /// The stores are opened where they were asked for, so a test never writes into the app's own
    /// Application Support directory.
    func testTheStoresOpenInTheGivenDirectory() throws {
        let (services, directory) = try makeServices()
        try fill(services)

        for name in ["journal.store", "favorites.store", "recipes.store", "goals.store"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                "\(name) is not in the given directory")
        }
    }

    /// The welcome flag is one of the display settings, so the erase clears it and the welcome shows
    /// again on the next launch. The display settings here live in a defaults suite of this test's own.
    func testEraseClearsTheWelcomeFlagWithTheDisplaySettings() throws {
        let suiteName = "healthnutrition.tests.erase-welcome.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let services = try AppServices.make(
            directory: directory, displayPreferences: UserDefaultsDisplayPreferences(defaults: suite),
            reminderScheduler: RecordingReminderScheduler())
        try fill(services)
        services.displayPreferences.setHasSeenWelcome(true)
        XCTAssertTrue(services.displayPreferences.hasSeenWelcome)

        XCTAssertTrue(services.connections.eraseAllData())

        XCTAssertFalse(services.displayPreferences.hasSeenWelcome)
    }

    /// Erase all data removes the pending daily reminder and the setting that asked for it, so a
    /// reminder never fires for a journal that no longer exists. The screen refreshes the reminder
    /// from its stored setting after an erase; the controller is refreshed the same way here.
    func testEraseCancelsTheReminderAndResetsItsSetting() async throws {
        let suiteName = "healthnutrition.tests.erase-reminder.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let scheduler = RecordingReminderScheduler()
        scheduler.settablePermission = .allowed
        let services = try AppServices.make(
            directory: directory,
            displayPreferences: UserDefaultsDisplayPreferences(defaults: suite),
            reminderScheduler: scheduler)
        try fill(services)
        await services.reminders.setOn(true)
        let pendingBeforeErase = await scheduler.pendingDailyCount()
        XCTAssertEqual(pendingBeforeErase, 1)

        XCTAssertTrue(services.connections.eraseAllData())

        let pendingAfterErase = await scheduler.pendingDailyCount()
        XCTAssertEqual(pendingAfterErase, 0)
        XCTAssertFalse(services.displayPreferences.isReminderOn)
        let leftover = suite.dictionaryRepresentation().keys.filter { $0.hasPrefix("display.reminder") }
        XCTAssertEqual(leftover.sorted(), [])
        services.reminders.refreshFromPreferences()
        XCTAssertFalse(services.reminders.isOn)
    }
}

/// A reminder scheduler that records calls and answers from settable state, for the app's own wiring.
final class RecordingReminderScheduler: ReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var currentPermission: ReminderPermission = .notDetermined
    private var pending: ReminderTime?

    var settablePermission: ReminderPermission {
        get { locked { currentPermission } }
        set { locked { currentPermission = newValue } }
    }

    func permission() async -> ReminderPermission {
        locked { currentPermission }
    }

    func requestPermission() async -> Bool {
        locked {
            currentPermission = .allowed
            return true
        }
    }

    func scheduleDaily(at time: ReminderTime) async {
        locked { pending = time }
    }

    func cancelDaily() {
        locked { pending = nil }
    }

    func pendingDailyCount() async -> Int {
        locked { pending == nil ? 0 : 1 }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
