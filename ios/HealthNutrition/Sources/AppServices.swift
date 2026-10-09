import Foundation
import NutritionJournal
import NutritionProviders
import NutritionUI

/// The stores and view models the app runs on.
///
/// The journal store holds a write lock per instance, so the app creates exactly one store per
/// database file and keeps it for its whole lifetime (see `docs/journal-store.md`). Favorites
/// live in a second file next to the journal file, recipes in a third, and the daily nutrient
/// targets in a fourth.
@MainActor
final class AppServices {
    let journalStore: SwiftDataJournalStore
    let favoritesStore: SwiftDataFavoritesStore
    /// Personal recipes, in their own file. Never shared or synced.
    let recipeStore: SwiftDataRecipeStore
    /// The daily nutrient targets, in their own file. Goals are data, not settings, so they are
    /// stored beside the journal and erased with it.
    let goalStore: SwiftDataGoalStore

    let today: TodayViewModel
    let journal: JournalViewModel
    let library: LibraryViewModel
    /// The Connections and privacy screen. It reads the same stores and, for its "Erase all data"
    /// action, holds all four as erasers, so one action empties every file the app keeps.
    let connections: ConnectionsPrivacyViewModel
    /// The Daily goals screen, reached from the Library screen's Connections section.
    let goals: GoalsViewModel
    /// The first-day checklist on Today. It reads the journal and the goals, and the display settings
    /// for the units step; the app shell loads it.
    let firstDayChecklist: FirstDayChecklistModel
    /// Barcode lookups in Add intake. One client for the app's lifetime, so its rolling rate-limit
    /// window is shared and never reset by opening the form again.
    let barcodeLookup: BarcodeProductLookup
    /// Delivers queued journal revisions to HealthKit.
    ///
    /// Built in every build and driven in every build, but only a debug build queues anything for it:
    /// the store below enables `.healthKit` only under `#if DEBUG`, so a release build's `runOnce`
    /// always finds an empty queue (see `docs/healthkit-writer.md`).
    let healthKitDelivery: HealthKitDeliveryWorker
    /// The display settings, shared by every screen that offers or shows units. One instance for the
    /// app's lifetime, so a unit system changed on the settings screen is the one the Today screen
    /// reads on the next reload rather than one screen's private copy.
    let displayPreferences: UserDefaultsDisplayPreferences
    /// The optional daily reminder. It reads its setting from `displayPreferences` and asks the system
    /// through the scheduler it was built with. The app shell syncs it at launch and when it becomes active.
    let reminders: ReminderController

    private init(
        journalStore: SwiftDataJournalStore, favoritesStore: SwiftDataFavoritesStore,
        recipeStore: SwiftDataRecipeStore, goalStore: SwiftDataGoalStore,
        displayPreferences: UserDefaultsDisplayPreferences = UserDefaultsDisplayPreferences(),
        reminderScheduler: ReminderScheduling
    ) {
        self.displayPreferences = displayPreferences
        let reminderErasures = ReminderErasures()
        self.reminders = ReminderController(
            preferences: displayPreferences, scheduler: reminderScheduler, erasures: reminderErasures)
        self.journalStore = journalStore
        self.favoritesStore = favoritesStore
        self.recipeStore = recipeStore
        self.goalStore = goalStore
        // Today's coverage reads the nutrient values each entry's product snapshot carries, so a
        // logged recipe or a looked-up product contributes what it states. An entry typed by hand has
        // no snapshot and stays unknown, never zero.
        today = TodayViewModel(
            store: journalStore, goals: goalStore, lookup: SnapshotNutrientFacts(), preferences: displayPreferences)
        journal = JournalViewModel(
            store: journalStore, goals: goalStore, lookup: SnapshotNutrientFacts(), preferences: displayPreferences)
        library = LibraryViewModel(store: journalStore, favorites: favoritesStore)
        goals = GoalsViewModel(store: goalStore, journal: journalStore, preferences: displayPreferences)
        firstDayChecklist = FirstDayChecklistModel(
            store: journalStore, goals: goalStore, preferences: displayPreferences)
        let reminderEraser = ReminderEraser(scheduler: reminderScheduler, erasures: reminderErasures)
        connections = ConnectionsPrivacyViewModel(
            store: journalStore, favorites: favoritesStore, appVersion: Self.appVersion,
            erasers: [journalStore, favoritesStore, recipeStore, goalStore, reminderEraser],
            preferences: displayPreferences)
        barcodeLookup = OpenFoodFactsProductLookup(
            client: OpenFoodFactsClient(appVersion: Self.appVersion))
        let totals = JournalSnapshotTotals(store: journalStore)
        healthKitDelivery = HealthKitDeliveryWorker(
            store: journalStore,
            writer: HealthKitSampleWriter(),
            totals: { intakeID, revision in try await totals.totals(intakeID: intakeID, revision: revision) }
        )
    }

    /// The marketing version from the bundle; the provider requires a User-Agent that names the app
    /// and its version. The debug "0" keeps the header well formed before the first build stamp.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Opens all four store files in `directory`, creating the directory and the files if needed.
    ///
    /// The directory is a parameter so a test can build a whole app on throwaway files instead of the
    /// real Application Support ones. The default is the app's own directory, unchanged.
    /// - Parameter displayPreferences: where the display settings live. A parameter so a test can pass
    ///   its own store rather than writing into the standard defaults domain.
    /// - Parameter reminderScheduler: the system's local notifications by default. A test passes a fake so
    ///   no notification is scheduled on the test device.
    static func make(
        directory: URL = defaultDirectory,
        displayPreferences: UserDefaultsDisplayPreferences = UserDefaultsDisplayPreferences(),
        reminderScheduler: ReminderScheduling = SystemReminderScheduler()
    ) throws -> AppServices {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Which destinations the journal queues work for.
        //
        // **A release build enables none.** Nothing is queued, so `healthKitDelivery` finds an empty
        // queue on every run and no Health authorization is ever asked for. Turning delivery on writes
        // real intake data into Health, which is a deliberate decision rather than a consequence of the
        // worker existing (docs/healthkit-writer.md).
        //
        // **A debug build enables `.healthKit` only**, and does so for one reason: the device
        // acceptance run (NC-08) has to drive the real writer against real entries, and a store that
        // queues nothing gives the worker nothing to deliver. The relay destination is off in every
        // build, for the same reason as above.
        let journalStore: SwiftDataJournalStore
        do {
            #if DEBUG
            journalStore = try SwiftDataJournalStore(
                url: directory.appendingPathComponent("journal.store"),
                enabledDestinations: [.healthKit]
            )
            #else
            journalStore = try SwiftDataJournalStore(
                url: directory.appendingPathComponent("journal.store"),
                enabledDestinations: []
            )
            #endif
        } catch {
            throw StoreStartupError.journal(error)
        }
        let favoritesStore: SwiftDataFavoritesStore
        do {
            favoritesStore = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        } catch {
            journalStore.close()
            throw StoreStartupError.favorites(error)
        }
        let recipeStore: SwiftDataRecipeStore
        do {
            recipeStore = try SwiftDataRecipeStore(url: directory.appendingPathComponent("recipes.store"))
        } catch {
            favoritesStore.close()
            journalStore.close()
            throw StoreStartupError.recipes(error)
        }
        do {
            let goalStore = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
            return AppServices(
                journalStore: journalStore, favoritesStore: favoritesStore, recipeStore: recipeStore,
                goalStore: goalStore, displayPreferences: displayPreferences,
                reminderScheduler: reminderScheduler)
        } catch {
            recipeStore.close()
            favoritesStore.close()
            journalStore.close()
            throw StoreStartupError.goals(error)
        }
    }

    /// Which store file failed to open at startup, so the failure screen names the right one.
    enum StoreStartupError: LocalizedError {
        case journal(Error)
        case favorites(Error)
        case recipes(Error)
        case goals(Error)

        var errorDescription: String? {
            switch self {
            case .journal(let error):
                return "The journal store file could not be opened: \(error.localizedDescription)"
            case .favorites(let error):
                return "The favorites store file could not be opened: \(error.localizedDescription)"
            case .recipes(let error):
                return "The recipes store file could not be opened: \(error.localizedDescription)"
            case .goals(let error):
                return "The daily goals store file could not be opened: \(error.localizedDescription)"
            }
        }
    }

    /// Application Support/HealthNutrition, created on first use.
    ///
    /// Nonisolated because it is the default argument of `make(directory:)` below, and a default
    /// argument is evaluated in a nonisolated context. It touches nothing but `FileManager`, so it has
    /// no reason to be on the main actor anyway.
    nonisolated static var defaultDirectory: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthNutrition", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
