import NutritionDomain
import NutritionJournal
import NutritionProviders
@testable import NutritionUI
import SwiftUI
import UIKit
import XCTest

@testable import HealthNutrition

/// Answers the account calls from memory, so the account screens can be captured with no network. Every
/// name, address and token here is invented.
final class ScreenshotAccountService: CommunityAccountServicing, @unchecked Sendable {
    private let session: CommunitySession?

    init(session: CommunitySession?) {
        self.session = session
    }

    func restore() async -> CommunitySession? { session }

    func signInWithApple(idToken: String, nonce: String) async throws -> CommunitySession {
        throw CommunityError.network
    }

    func requestEmailCode(email: String) async throws {}

    func discardLocalSession() async throws {}

    func verifyEmailCode(email: String, code: String) async throws -> CommunitySession {
        throw CommunityError.network
    }

    func signOut() async {}

    func profile() async throws -> CommunityProfile {
        CommunityProfile(displayName: "Ann", shareLabels: true)
    }

    func updateProfile(displayName: String?, shareLabels: Bool) async throws -> CommunityProfile {
        CommunityProfile(displayName: displayName, shareLabels: shareLabels)
    }

    func deleteAccount() async throws {}
}

/// Keeps saved meals in memory for one capture.
final class ScreenshotSavedMealStore: SavedMealStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SavedMeal] = []

    func meals() throws -> [SavedMeal] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func update(_ change: (inout [SavedMeal]) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var copy = stored
        try change(&copy)
        stored = copy
    }
}

/// Keeps supplement schedules and Taken marks in memory, so the supplement captures never read or write
/// the simulator's standard defaults.
final class ScreenshotSupplementStackStore: SupplementStackStoring {
    private var stored: [String: SupplementSchedule] = [:]
    private var marks: [String: SupplementTakenMark] = [:]

    func schedules() -> [String: SupplementSchedule] { stored }
    func save(_ schedules: [String: SupplementSchedule]) throws { stored = schedules }
    func takenMarks() -> [String: SupplementTakenMark] { marks }
    func saveTakenMarks(_ marks: [String: SupplementTakenMark]) throws { self.marks = marks }
}

/// Writes a PNG of each screen, in light and dark, for the design system.
///
/// The screens are the real views on a throwaway store filled with invented entries. The test only
/// runs when the `SCREENSHOT_DIR` environment variable names a directory (the screenshots workflow
/// passes it as `TEST_RUNNER_SCREENSHOT_DIR`), so the normal test run skips it. Each file is named
/// `<ViewName>-light.png` or `<ViewName>-dark.png`, the names `scripts/build_design_system.py` matches.
@MainActor
final class ScreenshotCaptureTests: XCTestCase {
    private let size = CGSize(width: 393, height: 852)
    private let intakeIDs = [
        "6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
        "7a2c3d4e-5f60-4b7c-9d8e-0f1a2b3c4d5e",
        "8b3d4e5f-6071-4c8d-8e9f-1a2b3c4d5e6f",
    ]

    /// Skips every capture before its fixtures are built when the screenshots workflow has not set
    /// `SCREENSHOT_DIR`, so the normal test run does no store work for these.
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]?.isEmpty == false else {
            throw XCTSkip("SCREENSHOT_DIR is not set; screenshots are captured by the screenshots workflow.")
        }
    }

    private func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR is not set; screenshots are captured by the screenshots workflow.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An app on throwaway files with a day of invented entries and two goals.
    private func makeSeededServices(productService: (any CommunityProductServicing)? = nil) throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionScreenshots", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let services = try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler(), productService: productService)
        let start = Calendar.current.startOfDay(for: Date())
        let zone = TimeZone.current.identifier
        // Protein is known only when the entry carries its product's facts, so the oats carry them.
        let oats = ProductDefinition(
            snapshotID: "screenshot-oats", productID: "screenshot-oats-product", name: "Rolled oats", brand: nil,
            barcode: nil, labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g)])
        let entries: [(String, String, String?, [IntakeComponent])] = [
            (intakeIDs[0], "food", "breakfast",
             [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 40, unit: .g),
              IntakeComponent(componentID: "milk", name: "Whole milk", amount: 150, unit: .mL)]),
            (intakeIDs[1], "water", nil,
             [IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)]),
            (intakeIDs[2], "food", "lunch",
             [IntakeComponent(componentID: "lentils", name: "Lentil soup", amount: 300, unit: .g)]),
        ]
        for (index, entry) in entries.enumerated() {
            let intake = Intake(
                id: entry.0, category: entry.1, occurredAt: start.addingTimeInterval(Double(60 * (index + 1))),
                timeZoneIdentifier: zone, meal: entry.2)
            try services.journalStore.create(intake, components: entry.3, product: index == 0 ? oats : nil, now: Date())
        }
        try services.goalStore.setGoal(NutrientGoal(nutrient: "protein", target: 90, unit: .g))
        try services.goalStore.setGoal(NutrientGoal(nutrient: "water", target: 2000, unit: .mL))
        return services
    }

    /// True when every sampled pixel is the same color, which is what a screen that failed to draw
    /// looks like.
    private func isUniform(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Averaged down, so thin text still moves some of the 256 samples away from the background.
        for offset in stride(from: 4, to: pixels.count, by: 4) {
            for channel in 0..<3 where abs(Int(pixels[offset + channel]) - Int(pixels[channel])) > 1 {
                return false
            }
        }
        return true
    }

    /// Hosts `content` in a visible window at iPhone size and writes one PNG per appearance.
    private func capture<Content: View>(_ name: String, width: CGFloat = 393, dynamicType: DynamicTypeSize = .large, @ViewBuilder _ content: () -> Content) throws {
        let directory = try outputDirectory()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        for (suffix, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: content().environment(\.dynamicTypeSize, dynamicType))
            window.makeKeyAndVisible()
            // Lets onAppear loads run and the List lay out before the picture is taken.
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            XCTAssertFalse(isUniform(image), "\(name)-\(suffix) rendered as one flat color")
        }
    }

    func testRootView() throws {
        _ = try outputDirectory()
        let services = try makeSeededServices()
        try captureProductSizes("RootView") { RootView(services: services) }
    }

    // The Today header on its own, so the design-system check finds a capture for it.
    func testNourishTodayHeader() throws {
        let services = try makeSeededServices()
        // The header only shows what the model has loaded, and nothing loads it on its own here.
        services.today.load(now: Date())
        // A blank header would still be a picture, so the test fails unless protein has a known total.
        let protein = try XCTUnwrap(services.today.progress.first { $0.nutrient == "protein" })
        guard case .known = protein.shownAmount else {
            return XCTFail("Protein has no known total on the seeded day, so the header would show a dash")
        }
        try capture("NourishTodayHeader") {
            ScrollView {
                NourishTodayHeader(model: services.today, onEditGoals: {}).padding()
            }
        }
    }

    func testTodayView() throws {
        let services = try makeSeededServices()
        try capture("TodayView") {
            NavigationStack {
                TodayView(
                    model: services.today, onAddIntake: {}, onEditGoals: {}, onSelect: { _ in })
            }
        }
    }

    func testJournalView() throws {
        let services = try makeSeededServices()
        try capture("JournalView") {
            NavigationStack { JournalView(model: services.journal, onSelect: { _ in }) }
        }
    }

    func testLibraryView() throws {
        let services = try makeProductServices()
        services.library.segment = .products
        try captureProductSizes("LibraryView") {
            NavigationStack {
                LibraryView(model: services.library, onAdded: {}, onOpenRecipes: {}, onProduct: { _ in }, onEditProduct: { _ in }, onLegacyProduct: { _ in }, onSearchProducts: {}, onNewProduct: {})
                    .navigationTitle("Library")
            }
        }
    }

    func testAppSettingsView() throws {
        let services = try makeSeededServices()
        // AppSettingsView installs its own Done item, as it does in RootView, so the capture adds none.
        try capture("AppSettingsView") {
            NavigationStack {
                AppSettingsView(goals: services.goals, connections: services.connections)
            }
        }
    }

    func testEntryDetailView() throws {
        let services = try makeSeededServices()
        try capture("EntryDetailView") {
            NavigationStack {
                EntryDetailView(
                    model: EntryDetailViewModel(
                        store: services.journalStore, intakeID: intakeIDs[0],
                        preferences: services.displayPreferences),
                    now: { Date() }, onFinished: {})
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") {} }
                    }
            }
        }
    }

    private func sampleRecipe() -> RecipeVersion {
        RecipeVersion(
            recipeID: "recipe-oat-bake", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour",
                    quantity: Quantity(value: Decimal(string: "200")!, unit: .g),
                    perUnit: ["energy": .known(Decimal(string: "3.6")!, .kcal)]),
                RecipeIngredient(
                    id: "yoghurt", name: "Plain yoghurt",
                    quantity: Quantity(value: Decimal(string: "150")!, unit: .g),
                    perUnit: ["energy": .known(Decimal(string: "0.6")!, .kcal)]),
            ],
            yield: .servings(4), createdAt: Date())
    }

    func testAddIntakeView() throws {
        let services = try makeSeededServices()
        try capture("AddIntakeView") {
            NavigationStack {
                AddIntakeView(
                    model: AddIntakeViewModel(
                        store: services.journalStore, now: Date(), lookup: services.barcodeLookup,
                        preferences: services.displayPreferences),
                    onSaved: {}, onScanLabel: {})
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testGoalsView() throws {
        let services = try makeSeededServices()
        services.goals.load()
        try capture("GoalsView") { NavigationStack { GoalsView(model: services.goals) } }
    }

    /// A setup sheet on its results step with invented answers. A new model per capture, because closing
    /// the sheet clears its answers and each light and dark picture opens its own sheet.
    func testGoalSetupView() throws {
        let services = try makeSeededServices()
        services.goals.load()
        try capture("GoalSetupView") {
            NavigationStack { GoalSetupView(model: sampleGoalSetup(services.goals)) }
        }
    }

    private func sampleGoalSetup(_ goals: GoalsViewModel) -> GoalSetupViewModel {
        let model = GoalSetupViewModel(goals: goals)
        model.aim = .maintain
        model.sex = .female
        model.ageText = "34"
        model.heightCentimetersText = "165"
        model.weightKilogramsText = "62"
        model.activity = .moderate
        model.next()
        model.next()
        model.next()
        model.next()
        return model
    }

    func testConnectionsPrivacyView() throws {
        let services = try makeSeededServices()
        try capture("ConnectionsPrivacyView") {
            NavigationStack { ConnectionsPrivacyView(model: services.connections) }
        }
    }

    func testRecipeListView() throws {
        let services = try makeSeededServices()
        try services.recipeStore.saveNewVersion(sampleRecipe())
        let model = RecipeListViewModel(store: services.recipeStore)
        model.load()
        try capture("RecipeListView") {
            NavigationStack { RecipeListView(model: model, onNew: {}, onOpen: { _ in }) }
        }
    }

    // The add flow's first screen and the library picker, as RootView presents them, with the Cancel item.
    func testAddHomeView() throws {
        let services = try makeSeededServices()
        let home = AddHomeViewModel(store: services.journalStore, meal: .lunch,
                                    lookup: services.barcodeLookup, preferences: services.displayPreferences)
        try capture("AddHomeView") {
            NavigationStack {
                AddHomeView(model: home, onBarcode: {}, onLabel: {}, onLibrary: {}, onType: {}, onChanged: {},
                            onSearchProducts: {})
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    // The amounts-only form as the Add screen presents it, with a few values typed in.
    func testQuickAddView() throws {
        let services = try makeSeededServices()
        let model = QuickAddViewModel(store: services.journalStore, meal: .lunch)
        model.caloriesText = "540"
        model.proteinText = "32"
        model.carbohydratesText = "60"
        try capture("QuickAddView") {
            NavigationStack {
                QuickAddView(model: model, onSaved: { _ in })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testAddLibraryPicker() throws {
        let services = try makeSeededServices()
        try services.recipeStore.saveNewVersion(sampleRecipe())
        let recipes = RecipeListViewModel(store: services.recipeStore)
        recipes.load()
        try capture("AddLibraryPicker") {
            NavigationStack {
                AddLibraryPicker(library: services.library, recipes: recipes, onPick: { _ in }, onRecipe: { _ in })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testRecipeDetailView() throws {
        let services = try makeSeededServices()
        let version = sampleRecipe()
        try services.recipeStore.saveNewVersion(version)
        try capture("RecipeDetailView") {
            NavigationStack {
                RecipeDetailView(
                    model: RecipeDetailViewModel(version: version, journal: services.journalStore),
                    onEdit: {}, onLogged: {})
            }
        }
    }

    func testRecipeEditorView() throws {
        let services = try makeSeededServices()
        let version = sampleRecipe()
        try services.recipeStore.saveNewVersion(version)
        try capture("RecipeEditorView") {
            NavigationStack {
                RecipeEditorView(
                    model: RecipeEditorViewModel(store: services.recipeStore, editing: version), onSaved: {})
            }
        }
    }

    /// An invented Nutrition Facts panel, read the way recognized camera text arrives: one string per line.
    func testLabelCaptureView() throws {
        let model = LabelCaptureViewModel()
        model.load(lines: [
            "Nutrition Facts", "Serving size 40 g", "Calories 150", "Total Fat 3 g", "Sodium 5 mg",
            "Total Carbohydrate 27 g", "Dietary Fiber 4 g", "Total Sugars 1 g", "Protein 5 g",
        ])
        try capture("LabelCaptureView") {
            // Mirrors LabelCaptureSheet, which wraps the view in its own stack, title and Cancel.
            NavigationStack {
                LabelCaptureView(model: model, onUse: { _ in })
                    .navigationTitle(model.isReviewing ? "Check the label" : "Scan the label")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testWelcomeView() throws {
        try capture("WelcomeView") { WelcomeView(onStart: {}, onRestore: {}) }
    }

    /// The first-day checklist on an empty store, as a first launch shows it.
    func testFirstDayChecklistView() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionScreenshots", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let model = FirstDayChecklistModel(
            store: store, goals: nil, preferences: InMemoryDisplayPreferences())
        model.load()
        try capture("FirstDayChecklistView") {
            ScrollView {
                FirstDayChecklistView(model: model, onLog: {}, onGoals: {}, onUnits: {})
                    .padding()
            }
        }
    }

    func testStartupFailureView() throws {
        try capture("StartupFailureView") {
            StartupFailureView(message: "The journal store file could not be opened.")
        }
    }

    private var sampleSession: CommunitySession {
        CommunitySession(
            accessToken: "screenshot-access", refreshToken: "screenshot-refresh",
            expiresAt: Date(timeIntervalSinceNow: 3600), userID: "screenshot-user", email: "reader@example.com")
    }

    /// The Account section of Settings for a signed-in person who has read the sharing disclosure.
    func testAccountSectionView() async throws {
        let model = AccountViewModel(
            service: ScreenshotAccountService(session: sampleSession), preferences: InMemoryDisplayPreferences())
        await model.load()
        model.acknowledgeDisclosure()
        try capture("AccountSectionView") {
            NavigationStack { Form { AccountSectionView(model: model) } }
        }
    }

    /// The sign-in sheet as a person sees it before signing in: Sign in with Apple and the email step.
    func testSignInSheet() throws {
        let model = AccountViewModel(
            service: ScreenshotAccountService(session: nil), preferences: InMemoryDisplayPreferences())
        try capture("SignInSheet") { SignInSheet(model: model) }
    }

    /// The first-run sharing disclosure, shown once after the first sign-in on a device.
    func testSharingDisclosureSheet() async throws {
        let model = AccountViewModel(
            service: ScreenshotAccountService(session: sampleSession), preferences: InMemoryDisplayPreferences())
        await model.load()
        try capture("SharingDisclosureSheet") { SharingDisclosureSheet(model: model) }
    }
}

private struct ScreenshotProductService: CommunityProductServicing {
    let productID = UUID(uuidString: "00000000-0000-4000-8000-000000000070")!
    func searchProducts(query: String, kind: ProductKind?, cursor: String?) async throws -> CommunityProductPage {
        let product = CommunityProduct(productID: productID, representativeRevision: "1", product: .custom(.init(name: "Synthetic mineral capsules", kind: .supplement, basis: .perServing, serving: .init(quantity: "2", unit: .capsule), facts: [.init(key: "iron", displayName: "Iron", state: .known, amount: "3", unit: .mg)])), source: .init(productID: productID, representativeRevision: "1", attribution: "Community"), verification: .init(status: .sharedUnverified), support: .init(distinctAccounts: "2", verificationThreshold: "3"), missingFacts: false, alternatives: [])
        return .init(products: [product], nextCursor: nil)
    }
    func capabilities() async throws -> ProductCatalogCapabilities { .init(supportedVersion: 2, enabled: true, limits: .init(maxEnvelopeBytes: 16384, maxFacts: 64, maxSearchLimit: 20), currentConsentVersion: 2, callerAcknowledgment: .init(version: 2, generation: "1"), consentGeneration: "1", sharingPermission: true, boundedPublicationVersion: 1) }
    func product(id: UUID) async throws -> CommunityProduct { try await searchProducts(query: "", kind: nil, cursor: nil).products[0] }
    func contribution(productID: UUID, expectedOwnerID: UUID) async throws -> ProductContributionState { .init(productID: productID, currentState: .none) }
    func publish(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt { throw ProductAPIError.unavailable }
    func withdraw(_ request: ProductWithdrawRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt { throw ProductAPIError.unavailable }
    func resolvePublishForWithdrawal(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductPublishResolution { throw ProductAPIError.unavailable }
    func acknowledgeConsent(version: Int, expectedOwnerID: UUID) async throws -> ProductConsentState { throw ProductAPIError.unavailable }
}

@MainActor extension ScreenshotCaptureTests {
    private func captureProductSizes<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) throws {
        try capture(name, content)
        try capture(name + "-accessibility", dynamicType: .accessibility3, content)
        try capture(name + "-320", width: 320, content)
        try capture(name + "-320-accessibility", width: 320, dynamicType: .accessibility3, content)
    }
    private func makeProductServices() throws -> AppServices {
        let services = try makeSeededServices(productService: ScreenshotProductService())
        let owner = UUID(), epoch = UUID()
        services.productSharing?.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        for (index, name) in ["Synthetic oat drink", "Synthetic mineral capsules", "Synthetic cereal"].enumerated() {
            let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: .init(name: name, kind: index == 1 ? .supplement : index == 0 ? .drink : .food, basis: .perServing))
            let operation = ProductShareOperation(ownerID: owner, localProductID: revision.localProductID, operationID: UUID(), clientRevisionID: revision.revisionID, kind: .publish, content: revision.content, consentGeneration: "1", epoch: epoch)
            try services.journalStore.saveCustomProduct(.init(revision: revision, publication: index == 0 ? nil : operation), now: Date())
            if index == 2 {
                let stored = try XCTUnwrap(try services.journalStore.productOperations(ownerID: owner).last)
                try services.journalStore.recordProductDelivery(.init(operationID: stored.operationID, ownerID: owner, epoch: epoch, storeEpoch: try XCTUnwrap(stored.storeEpoch), status: .needsReview, reason: .conflict))
            }
        }
        services.library.load()
        return services
    }
    func testLibraryVerificationPresentation() throws {
        for state in ["reviewed", "unreviewed", "unknown", "edited"] {
            let services = try makeSeededServices()
            let id = UUID()
            let verification = ProductVerification(status: state == "unreviewed" ? .sharedUnverified : .verified, source: state == "unreviewed" ? nil : "owner_reviewed")
            let product = CommunityProduct(productID: id, representativeRevision: "1", product: .custom(.init(name: "Synthetic imported product", kind: .food, basis: .per100g, facts: [])), source: .init(productID: id, representativeRevision: "1", attribution: "Community"), verification: verification, support: .init(distinctAccounts: "1", verificationThreshold: "3"), missingFacts: true, alternatives: [])
            let imported = try CustomProductMapping.importedRevision(from: product)
            let local: CustomProductRevision
            if state == "unknown" || state == "edited" {
                local = CustomProductRevision(localProductID: imported.localProductID, revisionID: UUID(), content: .init(name: state == "edited" ? "Synthetic edited product" : imported.content.name, kind: .food, basis: .per100g), source: imported.source)
            } else { local = imported }
            try services.journalStore.saveCustomProduct(.init(revision: local), now: Date())
            services.library.load(); services.library.segment = .products
            let expected = state == "reviewed" ? "Verified by owner review at import" : state == "unreviewed" ? "Not verified at import" : "Verification not checked"
            XCTAssertEqual(LibraryProductPresentation(local).verificationText, expected)
            try captureProductSizes("LibraryVerification-" + state) {
                NavigationStack {
                    LibraryView(model: services.library, onAdded: {}, onProduct: { _ in }, onEditProduct: { _ in })
                }
            }
        }
    }
    func testCustomProductEditorView() throws {
        let services = try makeProductServices()
        let model = CustomProductEditorViewModel(store: services.journalStore)
        model.name = "Synthetic mineral capsules"; model.kind = .supplement
        model.servingQuantity = "2"; model.servingUnit = .capsule
        model.facts = [.init(key: "iron", displayName: "Iron", state: .known, amount: "3", unit: .mg), .init(key: "ingredient:activity", displayName: "Activity", state: .known, amount: "5", unit: .iu)]
        try captureProductSizes("CustomProductEditorView") {
            NavigationStack { CustomProductEditorView(model: model, sharing: services.library.productSharing, onSaved: { _, _ in }) }
        }
    }
    func testCommunityProductSearchView() async throws {
        let services = try makeProductServices()
        let model = CommunityProductSearchViewModel(store: services.journalStore, service: ScreenshotProductService(), isSignedIn: { true })
        await model.search(query: "Synthetic", kind: nil)
        XCTAssertEqual(model.state, .loaded)
        try captureProductSizes("CommunityProductSearchView") {
            NavigationStack { CommunityProductSearchView(model: model, onSelect: { _ in }, onLegacy: { _ in }, onSignIn: {}) }
        }
    }
    func testRawKeyIdentitySharingPreviewAndReadOnlyInspection() async throws {
        let services = try makeProductServices()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/catalog-api/fixtures/shared-products-v2/key-identity-valid.json"))
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: data)
        let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: try request.product.domainContent())
        try services.journalStore.saveCustomProduct(.init(revision: revision), now: Date())
        let sharing = try XCTUnwrap(services.library.productSharing)
        await sharing.review(revision)
        let preview = try XCTUnwrap(sharing.preview)
        XCTAssertEqual(preview.revision.content.facts.count, 3)
        XCTAssertEqual(Set(preview.revision.content.facts.map(\.rawKeyIdentity)).count, 3)
        try captureProductSizes("RawKeyIdentitySharingPreview") {
            NavigationStack { Form { CustomProductSharingSection(item: revision, model: sharing) } }
        }
        sharing.cancelReview()
        let search = CommunityProductSearchViewModel(store: services.journalStore, service: ScreenshotProductService(), isSignedIn: { true })
        await search.search(query: "Synthetic", kind: nil)
        try search.inspect(XCTUnwrap(search.sharedResults.first))
        let before = try services.journalStore.customProducts()
        try captureProductSizes("SharedProductFactsInspection") {
            NavigationStack { CommunityProductSearchView(model: search, onSelect: { _ in }, onLegacy: { _ in }, onSignIn: {}) }
        }
        search.closeInspection()
        XCTAssertEqual(try services.journalStore.customProducts(), before)
    }
    func testProductDeliveryStatusAndAddCapsule() throws {
        let services = try makeProductServices()
        let products = try services.journalStore.customProducts()
        let item = try XCTUnwrap(products.first { $0.content.name == "Synthetic cereal" })
        let sharing = try XCTUnwrap(services.library.productSharing)
        XCTAssertEqual(sharing.status(item), .failed)
        try captureProductSizes("CustomProductStatus") {
            NavigationStack {
                Form {
                    Section { Text(item.content.name); Button("Edit product") {} }
                    CustomProductSharingSection(item: item, model: sharing)
                }.navigationTitle("Product status")
            }
        }
        try captureProductSizes("PrimaryCapsule") {
            NavigationStack {
                Text("Synthetic Add action layout")
            }.safeAreaInset(edge: .bottom) {
                PrimaryCapsule(AddIntakeAction.title, systemImage: "plus") {}.padding(.horizontal, DesignSpacing.m)
            }
        }
    }

    // MARK: Screens added in the 0.1.21 to 0.1.23 builds. Invented entries only; saved meals and supplement
    // schedules use in-memory stores so nothing reaches the simulator's defaults.

    func testTrendsView() throws {
        let services = try makeSeededServices()
        try capture("TrendsView") {
            NavigationStack { TrendsView(today: services.today, journal: services.journal) }
        }
    }

    func testInsightsHost() throws {
        let services = try makeSeededServices()
        services.journal.load(now: Date())
        try capture("InsightsHost") {
            NavigationStack { InsightsHost(journal: services.journal) }
        }
    }

    func testInsightsView() throws {
        let zone = TimeZone.current
        // Midday, so the newest entry is never in the future whatever time the run starts.
        let start = Calendar.current.startOfDay(for: Date())
        let now = start.addingTimeInterval(12 * 3_600)
        let entries = (0..<5).map { day in
            InsightsWeek.Entry(occurredAt: start.addingTimeInterval(Double(-86_400 * day) + 3_600), timeZoneIdentifier: zone.identifier)
        }
        let week = InsightsWeek.make(entries: entries, now: now, zone: zone)
        let averages = InsightsAverages(lines: [
            InsightsAverages.Line(id: "energy", text: "Energy: 1,850 kcal a day on average"),
            InsightsAverages.Line(id: "protein", text: "Protein: 82 g a day on average"),
        ])
        try capture("InsightsView") {
            NavigationStack { InsightsView(week: week, averages: averages) }
        }
    }

    func testNutrientGapsView() throws {
        let services = try makeSeededServices()
        try capture("NutrientGapsView") {
            NavigationStack { NutrientGapsView(makeModel: { NutrientGapsViewModel(store: services.journalStore) }) }
        }
    }

    func testMacroSplitSection() throws {
        let services = try makeSeededServices()
        // An energy goal, so the section shows its percent fields rather than the "set an energy goal" line.
        try services.goalStore.setGoal(NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal))
        services.goals.load()
        try capture("MacroSplitSection") {
            NavigationStack { Form { MacroSplitSection(model: services.goals) } }
        }
    }

    func testLogOnOtherDaysSheet() throws {
        try capture("LogOnOtherDaysSheet") {
            NavigationStack {
                LogOnOtherDaysSheet(message: "Rolled oats, 40 g", onLog: { _ in .close }, onCancel: {}, onDone: {})
            }
        }
    }

    func testLibrarySearchSections() throws {
        let services = try makeSeededServices()
        services.library.load()
        try capture("LibrarySearchSections") {
            NavigationStack { List { LibrarySearchSections(library: services.library, query: "", kind: nil, onPick: { _ in }) } }
        }
    }

    func testSavedMealSections() throws {
        let services = try makeSeededServices()
        // Its own in-memory list, so the saved meal never reaches the simulator's defaults or another capture.
        let meals = SavedMealsModel(store: ScreenshotSavedMealStore(), journal: services.journalStore)
        let breakfast = try services.journalStore.activeIntakes().filter { $0.id == intakeIDs[0] }
        XCTAssertTrue(meals.save(name: "Weekday breakfast", meal: .breakfast, intakes: breakfast))
        meals.load()
        try capture("SavedMealSections") {
            NavigationStack { List { SavedMealSections(model: meals, query: "", showsMeals: true, onLog: { _ in }) } }
        }
    }

    /// A supplement list on its own in-memory schedules: two invented supplements logged today, the first
    /// on the list with the standard schedule, the second left in the picker.
    private func makeSupplementStack(_ services: AppServices) throws -> SupplementStackViewModel {
        let start = Calendar.current.startOfDay(for: Date())
        let zone = TimeZone.current.identifier
        for (index, item) in [("vitamin-d", "Vitamin D", 25), ("magnesium", "Magnesium", 200)].enumerated() {
            let intake = Intake(
                id: UUID().uuidString.lowercased(), category: "supplement",
                occurredAt: start.addingTimeInterval(Double(600 + 60 * index)), timeZoneIdentifier: zone)
            try services.journalStore.create(
                intake, components: [IntakeComponent(componentID: item.0, name: item.1, amount: Decimal(item.2), unit: .mg)],
                product: nil, now: Date())
        }
        let model = SupplementStackViewModel(
            store: services.journalStore, favorites: services.favoritesStore, schedules: ScreenshotSupplementStackStore())
        model.load(now: Date())
        let first = try XCTUnwrap(model.candidates.first { $0.title.contains("Vitamin D") } ?? model.candidates.first)
        XCTAssertTrue(model.add(first, schedule: .standard, now: Date()))
        model.load(now: Date())
        return model
    }

    func testSupplementStackView() throws {
        let services = try makeSeededServices()
        let stack = try makeSupplementStack(services)
        try capture("SupplementStackView") {
            NavigationStack { SupplementStackView(model: stack) }
        }
    }

    func testSupplementStackPicker() throws {
        let services = try makeSeededServices()
        let stack = try makeSupplementStack(services)
        try capture("SupplementStackPicker") {
            NavigationStack { SupplementStackPicker(model: stack, now: { Date() }, onDone: {}) }
        }
    }

    func testSupplementScheduleEditor() throws {
        let services = try makeSeededServices()
        let stack = try makeSupplementStack(services)
        try capture("SupplementScheduleEditor") {
            NavigationStack {
                SupplementScheduleEditor(
                    model: stack, title: "Vitamin D", initial: .standard,
                    onSave: { _ in }, onRemove: nil, onCancel: {})
            }
        }
    }

    func testSupplementsTodayTile() throws {
        let services = try makeSeededServices()
        let stack = try makeSupplementStack(services)
        try capture("SupplementsTodayTile") {
            NavigationStack { List { SupplementsTodayTile(model: stack, now: { Date() }) } }
        }
    }
}
