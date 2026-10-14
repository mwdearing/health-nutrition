import Foundation
import NutritionJournal
import NutritionProviders
import NutritionUI
import Network

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
    /// Built and driven in every build. The store below queues `.healthKit` work for it, and nothing is
    /// written until the person connects Apple Health in Settings (see `docs/healthkit-writer.md`).
    let healthKitDelivery: HealthKitDeliveryWorker
    /// The one driver of that worker: the automatic runs, the authorization request and the queue's
    /// counts. One instance for the app's lifetime, because two drivers over one worker would each
    /// start a pass for the same queued operation.
    let healthKitDeliveryStatus: HealthKitDeliveryStatus
    /// The Apple Health row in Settings, backed by the driver above.
    let appleHealth: AppleHealthConnectionViewModel
    /// Today's steps, active energy and weight, read from Apple Health once the person allows it.
    let bodyActivity: BodyActivityViewModel
    /// The display settings, shared by every screen that offers or shows units. One instance for the
    /// app's lifetime, so a unit system changed on the settings screen is the one the Today screen
    /// reads on the next reload rather than one screen's private copy.
    let displayPreferences: UserDefaultsDisplayPreferences
    /// The optional daily reminder. It reads its setting from `displayPreferences` and asks the system
    /// through the scheduler it was built with. The app shell syncs it at launch and when it becomes active.
    let reminders: ReminderController
    /// The account, shown in Settings. Nil in a build without the project settings (an unsigned, CI or self
    /// build): then there is no account section and no account call is ever made.
    let account: AccountViewModel?
    /// The community catalog client, shared by the account, the barcode lookup and label uploads. Nil in the
    /// same builds as `account`, and then no catalog call is made.
    let community: CommunityClient?
    let productService: (any CommunityProductServicing)?
    /// Open Food Facts name search for Find products. Nil in builds that make no network calls at all.
    var productNameSearch: (any ProductNameSearching)? = nil
    let productSharing: ProductShareCoordinator?
    private var connectivityMonitor: NWPathMonitor?

    deinit { connectivityMonitor?.cancel() }

    private init(
        journalStore: SwiftDataJournalStore, favoritesStore: SwiftDataFavoritesStore,
        recipeStore: SwiftDataRecipeStore, goalStore: SwiftDataGoalStore,
        displayPreferences: UserDefaultsDisplayPreferences = UserDefaultsDisplayPreferences(),
        reminderScheduler: ReminderScheduling,
        productService: (any CommunityProductServicing)? = nil,
        accountServiceOverride: CommunityAccountServicing? = nil
    ) {
        self.displayPreferences = displayPreferences
        let community = Self.makeCommunity()
        let products: (any CommunityProductServicing)? = productService ?? community
        self.productService = products
        let productSharing = products.map { ProductShareCoordinator(store: journalStore, service: $0) }
        self.productSharing = productSharing
        let accountService: CommunityAccountServicing?
        if let accountServiceOverride = accountServiceOverride {
            accountService = accountServiceOverride
        } else {
            accountService = community
        }
        let account = accountService.map { AccountViewModel(service: $0, preferences: displayPreferences,
            productService: products, productSharing: productSharing) }
        self.community = community
        self.account = account
        let reminderErasures = ReminderErasures()
        let reminderController = ReminderController(
            preferences: displayPreferences, scheduler: reminderScheduler, erasures: reminderErasures)
        self.reminders = reminderController
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
        library = LibraryViewModel(store: journalStore, favorites: favoritesStore, productStore: journalStore,
            productSharing: CustomProductSharingModel(store: journalStore, coordinator: productSharing, service: products))
        goals = GoalsViewModel(store: goalStore, journal: journalStore, preferences: displayPreferences)
        firstDayChecklist = FirstDayChecklistModel(
            store: journalStore, goals: goalStore, preferences: displayPreferences)
        let reminderEraser = ReminderEraser(scheduler: reminderScheduler, erasures: reminderErasures)
        var reminderErasers: [JournalErasing] = [reminderEraser]
        // Only the system scheduler also schedules the custom reminders; a test's fake leaves them out.
        if let custom = reminderScheduler as? (ReminderScheduling & CustomReminderScheduling) {
            let store = UserDefaultsCustomReminderStore()
            reminderController.customReminders = CustomReminderController(
                store: store, permissions: custom, scheduler: custom, erasures: reminderErasures)
            reminderErasers.append(CustomReminderEraser(store: store, scheduler: custom, erasures: reminderErasures))
        }
        connections = ConnectionsPrivacyViewModel(
            store: journalStore, favorites: favoritesStore, appVersion: Self.appVersion,
            erasers: ([journalStore, favoritesStore, recipeStore, goalStore] as [JournalErasing]) + reminderErasers,
            preferences: displayPreferences,
            beforeErase: {
                if let owner = productSharing?.accountContext?.ownerID {
                    displayPreferences.setProductSharingPause(.erase, for: owner.uuidString)
                }
                account?.pauseSharingForErase()
                productSharing?.closeGate(reason: .erase)
            },
            afterSuccessfulErase: {
                displayPreferences.clearProductSharingPausesAfterErase()
                HealthKitReader.forgetReadAccess()
                account?.refreshAfterErase()
            },
            eraseLocalAccount: {
                guard let account else { return }
                try await account.discardLocalSession()
            })
        let openFoodFacts = OpenFoodFactsProductLookup(
            client: OpenFoodFactsClient(appVersion: Self.appVersion))
        barcodeLookup = Self.makeBarcodeLookup(primary: openFoodFacts, community: community, account: account)
        productNameSearch = openFoodFacts
        let totals = JournalSnapshotTotals(store: journalStore)
        let healthKitDelivery = HealthKitDeliveryWorker(
            store: journalStore,
            writer: HealthKitSampleWriter(),
            totals: { intakeID, revision in try await totals.totals(intakeID: intakeID, revision: revision) }
        )
        self.healthKitDelivery = healthKitDelivery
        let healthKitDeliveryStatus = HealthKitDeliveryStatus(
            healthKitDelivery: healthKitDelivery, store: journalStore, accessDefaults: .standard)
        self.healthKitDeliveryStatus = healthKitDeliveryStatus
        appleHealth = AppleHealthConnectionViewModel(connector: healthKitDeliveryStatus)
        bodyActivity = BodyActivityViewModel(
            reader: HealthKitReader(), unitSystem: { [displayPreferences] in displayPreferences.unitSystem })
        if let productSharing {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak productSharing] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in await productSharing?.runDueOperations(now: Date()) }
            }
            connectivityMonitor = monitor
            monitor.start(queue: DispatchQueue(label: "product-sharing-connectivity"))
        }
    }

    /// The community client, or nil when the build carries no project settings. The client reads them from the
    /// bundle's Info.plist and keeps the session in the Keychain. One client serves the account, the barcode
    /// lookup and the label uploads. A build with a site key also gets the human check for the emailed code.
    private static func makeCommunity() -> CommunityClient? {
        try? CommunityClient.make(
            infoDictionary: Bundle.main.infoDictionary, store: KeychainCommunitySessionStore(),
            captcha: makeCaptcha())
    }

    /// Open Food Facts first. A barcode it does not find is asked of the community catalog, for a person who is
    /// signed in. Without an account the lookup is Open Food Facts alone, as before accounts existed.
    private static func makeBarcodeLookup(
        primary: BarcodeProductLookup, community: CommunityClient?, account: AccountViewModel?
    ) -> BarcodeProductLookup {
        guard let community, let account else { return primary }
        return CommunityFallbackLookup(
            primary: primary, community: community, isSignedIn: { account.phase == .signedIn })
    }

    /// The human check for sign-in, or nil when the build has no site key. Without a provider the sign-in
    /// requests are sent as before, which is what a project without the check expects.
    private static func makeCaptcha() -> (any CommunityCaptcha)? {
        #if os(iOS)
        #if canImport(HCaptcha)
        return HCaptchaProvider.make(infoDictionary: Bundle.main.infoDictionary)
        #else
        return nil
        #endif
        #else
        return nil
        #endif
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
    /// - Parameter accountServiceOverride: a synthetic account service for checking the local-session erase
    ///   wiring. Nil in the app, where the account uses the community client.
    static func make(
        directory: URL = defaultDirectory,
        displayPreferences: UserDefaultsDisplayPreferences = UserDefaultsDisplayPreferences(),
        reminderScheduler: ReminderScheduling,
        productService: (any CommunityProductServicing)? = nil,
        accountServiceOverride: CommunityAccountServicing? = nil
    ) throws -> AppServices {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Which destinations the journal queues work for.
        //
        // **`.healthKit` only, in every build.** Queuing is not writing: an operation waits in the
        // outbox until the person connects Apple Health in Settings, and `HealthKitDeliveryStatus`
        // starts no automatic run before Health has been asked about every mapped type. An entry
        // logged before connecting is therefore written when they connect, and nothing reaches Health
        // for someone who never does (docs/healthkit-writer.md).
        //
        // The relay destination is off in every build.
        let journalStore: SwiftDataJournalStore
        do {
            journalStore = try SwiftDataJournalStore(
                url: directory.appendingPathComponent("journal.store"),
                enabledDestinations: [.healthKit]
            )
        } catch {
            throw StoreStartupError.journal(error)
        }
        // Best effort: the retention pass runs only here, at launch, and a failure never blocks launch.
        _ = try? journalStore.pruneAcknowledgedOutbox(now: Date())
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
                reminderScheduler: reminderScheduler, productService: productService,
                accountServiceOverride: accountServiceOverride)
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
