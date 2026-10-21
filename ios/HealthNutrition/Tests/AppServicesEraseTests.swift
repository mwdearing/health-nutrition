import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
@testable import NutritionUI
import XCTest

@testable import HealthNutrition

private final class EraseAccountService: CommunityAccountServicing, @unchecked Sendable {
    private(set) var discardCount = 0
    private(set) var signOutCount = 0
    private(set) var deleteCount = 0

    func restore() async -> CommunitySession? { nil }
    func signInWithApple(idToken: String, nonce: String) async throws -> CommunitySession { throw CommunityError.network }
    func requestEmailCode(email: String) async throws {}
    func verifyEmailCode(email: String, code: String) async throws -> CommunitySession { throw CommunityError.network }
    func signOut() async throws { signOutCount += 1 }
    func discardLocalSession() async throws { discardCount += 1 }
    func profile() async throws -> CommunityProfile { CommunityProfile(displayName: nil, shareLabels: true) }
    func updateProfile(displayName: String?, shareLabels: Bool) async throws -> CommunityProfile {
        CommunityProfile(displayName: displayName, shareLabels: shareLabels)
    }
    func deleteAccount() async throws { deleteCount += 1 }
}

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

    func testEraseClosesProductDeliveryBeforeClearingActualStoreAndDropsSuspendedReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let productService = EraseProductService()
        let suite = "synthetic.product.erase.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices.make(directory: directory, displayPreferences: UserDefaultsDisplayPreferences(defaults: defaults),
            reminderScheduler: RecordingReminderScheduler(), productService: productService)
        let coordinator = try XCTUnwrap(services.productSharing), owner = UUID(), epoch = UUID()
        let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic", kind: .food, basis: .per100g))
        let publication = ProductShareOperation(ownerID: owner, localProductID: revision.localProductID, operationID: UUID(), clientRevisionID: revision.revisionID,
            kind: .publish, content: revision.content, consentGeneration: "1", epoch: epoch)
        try services.journalStore.saveCustomProduct(CustomProductSave(revision: revision, publication: publication), now: when)
        coordinator.updateAccountContext(ProductShareAccountContext(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let delivery = Task { await coordinator.runDueOperations(now: when) }
        let publicationStarted = await productService.waitForPublication(timeoutSeconds: 5)
        guard publicationStarted else {
            let erasedBeforeReceipt = await services.connections.eraseAllData()
            XCTAssertTrue(erasedBeforeReceipt)
            await productService.finish(ProductDeliveryReceipt(operationID: publication.operationID, productID: UUID(), acknowledgedRevision: "1",
                currentRevision: "1", currentState: .active, replayed: false))
            await delivery.value
            XCTFail("Product delivery did not reach publish within five seconds")
            return
        }
        let erasedDuringPublish = await services.connections.eraseAllData()
        XCTAssertTrue(erasedDuringPublish)
        XCTAssertEqual(coordinator.pauseReason, .erase)
        await productService.finish(ProductDeliveryReceipt(operationID: publication.operationID, productID: UUID(), acknowledgedRevision: "1",
            currentRevision: "1", currentState: .active, replayed: false))
        await delivery.value
        XCTAssertTrue(try services.journalStore.productOperations(ownerID: owner).isEmpty)
        XCTAssertTrue(try services.journalStore.customProducts().isEmpty)
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
    func testEraseEmptiesTheJournalTheFavoritesTheRecipesAndTheGoals() async throws {
        let (services, _) = try makeServices()
        try fill(services)

        let erased = await services.connections.eraseAllData()

        XCTAssertTrue(erased)
        XCTAssertNil(services.connections.errorMessage)
        XCTAssertTrue(try services.journalStore.activeIntakes().isEmpty)
        XCTAssertTrue(try services.favoritesStore.list().isEmpty)
        XCTAssertTrue(try services.recipeStore.list().recipes.isEmpty)
        XCTAssertTrue(try services.goalStore.goals().isEmpty)
    }

    /// Every production store is in the erase, in the pinned order: widget data first, journal after the lists. The
    /// custom reminders join only with the system scheduler, which the test scheduler does not provide.
    func testTheBuilderNamesWithoutTheSystemSchedulerAreInOrder() throws {
        XCTAssertEqual(eraseNamesFromBuilderInputs(withCustomReminders: false), [
            "widget data", "saved meals", "supplements", "reminders",
            "journal", "favorites", "recipes", "goals",
        ])
    }

    /// A system scheduler that also supports custom reminders adds "custom reminders" to the erase, after the
    /// daily reminders and before the journal, so a custom request is cleared too.
    func testTheBuilderNamesIncludeCustomRemindersWhenTheSchedulerSupportsThem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(eraseNamesFromBuilderInputs(withCustomReminders: true), [
            "widget data", "saved meals", "supplements", "reminders", "custom reminders",
            "journal", "favorites", "recipes", "goals",
        ])
    }

    /// The custom-reminder decision, both sides: a scheduler that takes custom reminders gets the custom side, a fake
    /// that does not gets nothing, so the custom eraser joins the erase only where the system scheduler is wired.
    func testTheCustomReminderDecisionTakesTheCustomSideOnlyWhereTheSchedulerSupportsIt() {
        XCTAssertNotNil(AppServices.customReminderScheduling(of: CustomCapableReminderScheduler()))
        XCTAssertNil(AppServices.customReminderScheduling(of: RecordingReminderScheduler()))
    }

    /// The erase order, built by the same function production calls, from stores in a temporary directory and fakes
    /// for the reminder centers. The custom eraser joins only when the scheduler takes custom reminders.
    private func eraseNamesFromBuilderInputs(withCustomReminders: Bool) -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reminders: [JournalErasing] = [
            ReminderEraser(scheduler: RecordingReminderScheduler(), erasures: ReminderErasures()),
        ]
        if withCustomReminders {
            reminders.append(CustomReminderEraser(
                store: UserDefaultsCustomReminderStore(), scheduler: CustomCapableReminderScheduler(),
                erasures: ReminderErasures()))
        }
        let order = ConnectionsPrivacyViewModel.eraseOrder(ConnectionsPrivacyViewModel.EraseStores(
            widgets: WidgetSnapshotEraser(), savedMeals: UserDefaultsSavedMealStore(),
            supplements: UserDefaultsSupplementStackStore(), reminders: reminders,
            journal: try! SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            favorites: try! SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store")),
            recipes: try! SwiftDataRecipeStore(url: directory.appendingPathComponent("recipes.store")),
            goals: try! SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))))
        return order.map(\.erasureName)
    }

    /// Each store lands in its own slot: the erase list gets the instance it was given, in the field it was given to.
    /// Each parameter of eraseStores has its own concrete type, so a swap of two labels at the call does not compile.
    func testEraseStoresKeepsEachStoreInItsOwnSlot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let widgets = WidgetSnapshotEraser()
        let savedMeals = UserDefaultsSavedMealStore()
        let supplements = UserDefaultsSupplementStackStore()
        let daily = ReminderEraser(scheduler: RecordingReminderScheduler(), erasures: ReminderErasures())
        let custom = CustomReminderEraser(
            store: UserDefaultsCustomReminderStore(), scheduler: CustomCapableReminderScheduler(),
            erasures: ReminderErasures())
        let journal = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let recipes = try SwiftDataRecipeStore(url: directory.appendingPathComponent("recipes.store"))
        let goals = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))

        let stores = AppServices.eraseStores(
            widgets: widgets, savedMeals: savedMeals, supplements: supplements, dailyReminders: daily,
            customReminders: custom, journal: journal, favorites: favorites, recipes: recipes, goals: goals)

        XCTAssertTrue(stores.widgets === widgets)
        XCTAssertTrue(stores.savedMeals === savedMeals)
        XCTAssertTrue(stores.supplements === supplements)
        XCTAssertEqual(stores.reminders.count, 2)
        XCTAssertTrue(stores.reminders[0] === daily)
        XCTAssertTrue(stores.reminders[1] === custom)
        XCTAssertTrue(stores.journal === journal)
        XCTAssertTrue(stores.favorites === favorites)
        XCTAssertTrue(stores.recipes === recipes)
        XCTAssertTrue(stores.goals === goals)
    }

    /// The app supplies its account model to the privacy erase hook. The hook drops the local session
    /// while leaving server sign-out and account deletion untouched.
    func testEraseUsesTheAppWiredLocalAccountHookOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let service = EraseAccountService()
        let services = try AppServices.make(
            directory: directory, reminderScheduler: RecordingReminderScheduler(), accountServiceOverride: service)

        let erased = await services.connections.eraseAllData()
        let erasedAgain = await services.connections.eraseAllData()

        XCTAssertTrue(erased)
        XCTAssertTrue(erasedAgain)
        XCTAssertEqual(service.discardCount, 2)
        XCTAssertEqual(service.signOutCount, 0)
        XCTAssertEqual(service.deleteCount, 0)
        XCTAssertEqual(services.account?.phase, .signedOut)
        XCTAssertEqual(services.account?.email, "")
    }

    /// An erase is a new start rather than a broken store: the same store instances take a write
    /// afterwards and the entry is readable again.
    func testTheStoresStayUsableAfterAnErase() async throws {
        let (services, _) = try makeServices()
        try fill(services)
        let eraseResult1 = await services.connections.eraseAllData()
        XCTAssertTrue(eraseResult1)

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
    func testEraseClearsTheWelcomeFlagWithTheDisplaySettings() async throws {
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

        let eraseResult2 = await services.connections.eraseAllData()
        XCTAssertTrue(eraseResult2)

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

        let eraseResult3 = await services.connections.eraseAllData()
        XCTAssertTrue(eraseResult3)

        let pendingAfterErase = await scheduler.pendingDailyCount()
        XCTAssertEqual(pendingAfterErase, 0)
        XCTAssertFalse(services.displayPreferences.isReminderOn)
        let leftover = suite.dictionaryRepresentation().keys.filter { $0.hasPrefix("display.reminder") }
        XCTAssertEqual(leftover.sorted(), [])
        services.reminders.refreshFromPreferences()
        XCTAssertFalse(services.reminders.isOn)
    }
}

/// A daily scheduler that also takes custom reminders, as the system scheduler does.
final class CustomCapableReminderScheduler: ReminderScheduling, CustomReminderScheduling, @unchecked Sendable {
    func permission() async -> ReminderPermission { .notDetermined }
    func requestPermission() async -> Bool { false }
    func scheduleDaily(at time: ReminderTime) async throws {}
    func cancelDaily() {}
    func pendingDailyCount() async -> Int { 0 }
    func replaceAll(with reminders: [CustomReminder]) async throws {}
    func cancel(ids: [UUID]) {}
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


private actor EraseProductService: CommunityProductServicing {
    private var reply: CheckedContinuation<ProductDeliveryReceipt, Never>?
    private var arrival: CheckedContinuation<Bool, Never>?
    func waitForPublication(timeoutSeconds: Double) async -> Bool {
        if reply != nil { return true }
        return await withCheckedContinuation { continuation in
            arrival = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self.expirePublicationWait()
            }
        }
    }
    private func expirePublicationWait() {
        arrival?.resume(returning: false)
        arrival = nil
    }
    func finish(_ receipt: ProductDeliveryReceipt) { reply?.resume(returning: receipt) }
    func publish(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt {
        await withCheckedContinuation { reply = $0; arrival?.resume(returning: true); arrival = nil }
    }
    func capabilities() async throws -> ProductCatalogCapabilities {
        ProductCatalogCapabilities(supportedVersion: 2, enabled: true, limits: ProductCatalogLimits(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20),
            currentConsentVersion: 2, callerAcknowledgment: ProductConsentAcknowledgment(version: 2, generation: "1"), consentGeneration: "1", sharingPermission: true,
            boundedPublicationVersion: 1)
    }
    func resolvePublishForWithdrawal(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductPublishResolution { throw ProductAPIError.unavailable }
    func withdraw(_ request: ProductWithdrawRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt { throw ProductAPIError.unavailable }
    func contribution(productID: UUID, expectedOwnerID: UUID) async throws -> ProductContributionState { throw ProductAPIError.unavailable }
    func acknowledgeConsent(version: Int, expectedOwnerID: UUID) async throws -> ProductConsentState { throw ProductAPIError.unavailable }
    func searchProducts(query: String, kind: ProductKind?, cursor: String?) async throws -> CommunityProductPage { throw ProductAPIError.unavailable }
    func product(id: UUID) async throws -> CommunityProduct { throw ProductAPIError.unavailable }
}

