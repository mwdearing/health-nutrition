import Foundation
import SwiftUI
import UIKit
import NutritionJournal
import NutritionDomain
import NutritionUI

/// The tab shell: Today, Diary (the journal), Library, Trends and Settings, all reading the same store.
@MainActor
struct RootView: View {
    let services: AppServices
    /// Observed rather than reached through `services`, so publishing a change on it re-evaluates this
    /// shell. Reading it through the plain property left the erase handler below waiting for some
    /// unrelated change before it ran, with erased entries still on screen.
    @ObservedObject var connections: ConnectionsPrivacyViewModel

    @State private var showingWelcome: Bool
    /// The welcome is skipped while the design-system screenshots are captured, so the shell's own
    /// picture is not covered by it.
    private static var skipsWelcome: Bool {
        #if DEBUG
        return isCapturingScreenshots
        #else
        return false
        #endif
    }
    /// One presentation is never switched off and another on in the same action: the second is asked
    /// for here and shown when the first has finished going away.
    @State private var settingsAfterWelcome = false
    @State private var settingsAfterAdding = false
    @State private var welcomeAfterSettings = false

    @State private var selection: AppTab = .today
    @State private var addHome: AddHomeViewModel?
    @State private var productSearchModel: CommunityProductSearchViewModel?
    @State private var addIntakeModel: AddIntakeViewModel?
    @State private var labelCapture: LabelCaptureViewModel?
    @StateObject private var addNavigation = AddNavigationModel()
    @State private var addFlowError: String?
    @State private var selectedIntakeID: String?
    /// Whether the settings sheet is up, and whether it opens straight onto the daily goals (Today's
    /// "Edit goals" link) rather than onto the settings list.
    @State private var showingSettings = false
    @State private var settingsOpensGoals = false
    /// Held rather than kept as plain view state, so the erase below closes the recipe sheet and drops
    /// its routes through one method a test can call.
    @StateObject private var recipeNavigation = RecipeNavigation()
    @State private var recipeList: RecipeListViewModel
    @StateObject private var privacyShield = PrivacyShieldController()
    @Environment(\.scenePhase) private var scenePhase
    /// Today's view model, observed so this body is re-evaluated when its values change. Read only for
    /// the water total below, which is the one journal write that does not go through `reload()`.
    @ObservedObject var todayModel: TodayViewModel
    /// The app's one HealthKit delivery driver: the automatic runs below, the Apple Health row in
    /// Settings and the debug section all act on this same state.
    private var healthKitDeliveryStatus: HealthKitDeliveryStatus { services.healthKitDeliveryStatus }
    #if DEBUG
    /// The design-system screenshots run a debug build with `SCREENSHOT_DIR` set. They leave out the
    /// debug-only HealthKit tab and delivery line so the pictures show the app's own screens.
    private static let isCapturingScreenshots = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] != nil
    // One runner for the app's lifetime, so the transcript survives tab switches. It is handed the
    // same delivery status the debug section shows, so a request made here reaches the real writer.
    @State private var healthKitSpike: HealthKitSpikeRunner
    #endif

    init(services: AppServices) {
        self.services = services
        _connections = ObservedObject(wrappedValue: services.connections)
        _showingWelcome = State(initialValue: !services.displayPreferences.hasSeenWelcome && !Self.skipsWelcome)
        _recipeList = State(initialValue: RecipeListViewModel(store: services.recipeStore))
        _todayModel = ObservedObject(wrappedValue: services.today)
        #if DEBUG
        _healthKitSpike = State(initialValue: HealthKitSpikeRunner(deliveryStatus: services.healthKitDeliveryStatus))
        #endif
    }

    private enum AppTab: Hashable {
        case today
        case journal
        case library
        case trends
        /// Not a screen: choosing it opens the settings sheet and returns to the tab the person was on.
        case settings
        #if DEBUG
        case spike
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                TodayView(
                    model: services.today,
                    onAddIntake: { startAddingIntake() },
                    onEditGoals: { openSettings(goals: true) },
                    // Today's rows are the same entries the Journal lists, so they open the same
                    // entry screen: an entry logged late on the wrong day is corrected from where
                    // it is noticed rather than only from the Journal tab.
                    onSelect: { selectedIntakeID = $0 },
                    onAddToMeal: { meal in self.startAddingIntake(meal: meal) },
                    checklist: services.firstDayChecklist,
                    onOpenUnits: { self.openSettings(goals: false) },
                    bodyActivity: services.bodyActivity,
                    supplementStack: services.supplementStack,
                    onSupplementLogged: { reload() }
                )
                .toolbar { settingsToolbar }
                #if DEBUG
                // One line, because a delivery that is parked or waiting for a person should be visible
                // where the entries it belongs to are, not only on the debug tab. Debug builds only.
                .safeAreaInset(edge: .bottom) {
                    if !Self.isCapturingScreenshots {
                        Text(healthKitDeliveryStatus.summaryLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                #endif
            }
            // The Add capsule goes inside each tab's own stack: an inset on the tab view itself is
            // laid out against the bottom of the screen and covers the tab bar.
            .safeAreaInset(edge: .bottom) { addCapsule }
            .tabItem { Label("Today", systemImage: "sun.max") }
            .tag(AppTab.today)

            NavigationStack {
                JournalView(model: services.journal, onSelect: { selectedIntakeID = $0 })
                    .toolbar { settingsToolbar }
            }
                .safeAreaInset(edge: .bottom) { addCapsule }
                .tabItem { Label("Diary", systemImage: "book.closed") }
                .tag(AppTab.journal)

            // In a navigation stack like the other two tabs. Settings, goals and the privacy screen are
            // reached from the gear on every tab, not from here.
            NavigationStack {
                LibraryView(
                    model: services.library, onAdded: { reload() }, onOpenRecipes: { openRecipes() },
                    onOpen: { template in self.openAddDetails(prefilledFrom: template) },
                    onProduct: { product in self.startProductDetails(product) },
                    onEditProduct: { product in self.startProductEditor(revision: product) },
                    onLegacyProduct: { draft in self.startProductEditor(legacy: draft) },
                    onSearchProducts: { self.startProductSearch() },
                    onNewProduct: { self.startProductEditor() }
                )
                .navigationTitle("Library")
                .toolbar { settingsToolbar }
            }
                .safeAreaInset(edge: .bottom) { addCapsule }
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(AppTab.library)
                .sheet(isPresented: $recipeNavigation.showingRecipes) {
                    recipesSheet
                }

            NavigationStack {
                TrendsView(today: services.today, journal: services.journal)
                    .toolbar { settingsToolbar }
            }
                .safeAreaInset(edge: .bottom) { addCapsule }
                .tabItem { Label("Trends", systemImage: "chart.bar") }
                .tag(AppTab.trends)

            // The mockup's fourth tab. The settings sheet keeps every existing entry point (goals, the
            // welcome, erase), so this tab only opens it and puts the selection back.
            Color.clear
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)

            #if DEBUG
            // Debug builds only: the real HealthKit delivery driver, then the spike that measured how
            // HealthKit resolves a repeated sync identifier. Not in the screenshots.
            if !Self.isCapturingScreenshots {
                NavigationStack {
                    List {
                        HealthKitDeliveryDebugSection(status: healthKitDeliveryStatus)
                        HealthKitSpikeSteps(runner: healthKitSpike)
                    }
                    .navigationTitle("HealthKit")
                }
                .tabItem { Label("HealthKit", systemImage: "waveform.path.ecg") }
                .tag(AppTab.spike)
            }
            #endif
        }
        .onChange(of: selection) { previous, current in
            let outcome = SettingsTabRedirect.resolve(
                previous: previous, current: current, settings: .settings, fallback: .today)
            guard outcome.opensSettings else { return }
            selection = outcome.selection
            openSettings(goals: false)
        }
        .background {
            PrivacyShieldWindowAttachment(controller: privacyShield, phase: scenePhase)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        // One entry sheet for the whole shell, so Today and the Journal open the same screen: both
        // name an entry into `selectedIntakeID` and one sheet presents over whichever tab is showing.
        // Hanging it on a single tab would leave the other tab's rows dead.
        .sheet(isPresented: detailSheetPresented) {
            NavigationStack {
                if let intakeID = selectedIntakeID {
                    EntryDetailView(
                        model: EntryDetailViewModel(
                            store: services.journalStore, intakeID: intakeID,
                            preferences: services.displayPreferences),
                        now: { Date() },
                        onFinished: {
                            selectedIntakeID = nil
                            reload()
                        },
                        // A re-armed delivery is sent by the next pass, so one is asked for now. Only the pass:
                        // the open entry keeps its own model, which the re-arm already reloaded.
                        onRetried: { deliverToHealthKit() }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { selectedIntakeID = nil }
                        }
                    }
                }
            }
        }
        // Settings from the gear on any tab, in its own navigation stack so the goals and the privacy
        // screen push inside it.
        .sheet(isPresented: $showingSettings, onDismiss: {
            self.reload()
            if self.welcomeAfterSettings {
                self.welcomeAfterSettings = false
                self.showingWelcome = true
            }
        }) {
            NavigationStack {
                AppSettingsView(
                    goals: services.goals, connections: connections, reminders: services.reminders,
                    account: services.account, appleHealth: services.appleHealth,
                    now: { Date() }, opensGoals: settingsOpensGoals,
                    onShowWelcome: { self.welcomeAfterSettings = true; self.showingSettings = false }
                )
            }
        }
        // The welcome, shown once: on the first launch, and again when Settings asks for it. Settings
        // is opened from this cover's dismissal when Restore was chosen, never in the same action.
        .fullScreenCover(isPresented: $showingWelcome, onDismiss: {
            if self.settingsAfterWelcome {
                self.settingsAfterWelcome = false
                self.openSettings(goals: false)
            }
        }) {
            WelcomeView(
                onStart: {
                    self.services.displayPreferences.setHasSeenWelcome(true)
                    self.showingWelcome = false
                },
                onRestore: {
                    self.services.displayPreferences.setHasSeenWelcome(true)
                    self.settingsAfterWelcome = true
                    self.showingWelcome = false
                })
        }
        // The checklist's steps are read when the shell appears; later reads come from reload().
        .onAppear { self.services.firstDayChecklist.load() }
        // The daily reminder's pending request is brought in line with its setting at launch. It never
        // asks for permission here; that happens only when a person switches the reminder on.
        .task { await self.services.reminders.syncOnLaunch() }
        // Restore a stored sign-in at launch, not when Settings first opens, so the catalog lookup and the
        // upload gate work from the first screen.
        .task {
            await self.services.account?.load()
            await self.services.productSharing?.runDueOperations(now: Date())
        }
        // Today's totals depend on the local day: recompute them when the app comes back to the
        // foreground, e.g. after midnight or a time-zone change while it stayed on one tab.
        .onChange(of: scenePhase) { _, phase in
            privacyShield.update(phase: phase)
            if phase == .active {
                reload()
                Task { await self.services.reminders.syncOnLaunch() }
                Task {
                    await self.services.account?.refreshProductSharing()
                    await self.services.productSharing?.runDueOperations(now: Date())
                }
            }
        }
        // UIKit posts this before the app-switcher snapshot. Filter by the attached scene so a
        // different window resigning active cannot leave this still-active window covered.
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
            privacyShield.coverBeforeSnapshot(for: notification.object as AnyObject?)
        }
        // An erase in Settings empties the stores these tabs read, so their
        // held values go with it rather than showing entries that no longer exist.
        .onChange(of: connections.eraseGeneration) { _, _ in
            // A recipe detail or editor holds its own copy of the recipe, so close those routes too:
            // otherwise an erased recipe stays on screen and can still be logged.
            recipeNavigation.reset()
            self.finishAdding()
            reload()
            recipeList.load()
            services.goals.reloadAfterErase()
            services.firstDayChecklist.load()
        }
        // A restore writes the journal without going through the normal view-model reload path. This
        // generation advances for a successful or partial restore so held Today/Journal rows catch up.
        .onChange(of: connections.journalRestoreGeneration) { _, _ in
            reload()
        }
        // A restore on the Connections and privacy screen writes the journal without going through
        // `reload()`, so it is watched here. The restore queues nothing of its own; this is here so a
        // restore that follows a parked delivery is delivered like any other journal change.
        .onChange(of: connections.importState) { _, _ in
            deliverToHealthKit()
        }
        // The water button on Today writes through its own view model and does not reload the tabs, so
        // it is the one journal change `reload()` never sees. Watching the total covers it and its undo.
        // Observed rather than read through `services`, so the change is actually delivered to this body.
        .onChange(of: todayModel.waterTotalMilliliters) { _, _ in
            deliverToHealthKit()
        }
        .fullScreenCover(item: $addHome, onDismiss: {
            self.addNavigation.reset(); self.reload()
            if self.settingsAfterAdding { self.settingsAfterAdding = false; self.openSettings(goals: false) }
        }) { home in
            NavigationStack(path: self.$addNavigation.path) {
                AddHomeView(
                    model: home,
                    onBarcode: { self.openAddRoute(.barcodeScanner, home: home) },
                    onLabel: { self.openAddRoute(.labelScanner, home: home) },
                    onLibrary: { self.openAddRoute(.library, home: home) },
                    onType: { self.openAddRoute(.details(nil), home: home) },
                    onChanged: { self.reload() },
                    onNewProduct: { self.openProductEditor(home: home) },
                    onSearchProducts: { self.openAddRoute(.productSearch, home: home) }
                )
                .navigationDestination(for: AddRoute.self) { route in
                    self.addDestination(route, home: home)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { self.finishAdding() }
                    }
                }
            }
        }
    }

    /// The gear on every tab. Opens Settings.
    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                openSettings(goals: false)
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel("Settings")
            }
            .accessibilityLabel("Settings")
        }
    }

    /// The shared AddIntakeAction.title capsule, laid over the bottom of every tab.
    private var addCapsule: some View {
        PrimaryCapsule(AddIntakeAction.title, systemImage: "plus") {
            startAddingIntake()
        }
        .accessibilityLabel(AddIntakeAction.title)
        .padding(.horizontal, DesignSpacing.m)
        .padding(.bottom, DesignSpacing.s)
    }

    /// Opens Settings, onto the daily goals where Today's "Edit goals" asked for them.
    private func openSettings(goals: Bool) {
        settingsOpensGoals = goals
        showingSettings = true
    }

    private func startAddingIntake(meal: MealLabel? = nil) {
        self.addNavigation.reset()
        self.addFlowError = nil
        self.addHome = self.makeAddHome(meal: meal)
    }

    private func makeAddHome(meal: MealLabel?) -> AddHomeViewModel {
        let services = self.services
        return AddHomeViewModel(
            store: services.journalStore, meal: meal,
            scannerAvailability: AddScannerAvailability(
                barcode: BarcodeScanner.isAvailable, label: LabelTextScanner.isAvailable),
            lookup: services.barcodeLookup, preferences: services.displayPreferences,
            labelSubmitter: services.community,
            isSharingAllowed: { services.account?.sharingAllowed ?? false })
    }

    /// Opens Add on its details form, prefilled from a Library item. Nothing is logged until Save.
    private func openAddDetails(prefilledFrom template: RepeatTemplate) {
        // Nothing to prefill: report it and open nothing.
        guard !template.components.isEmpty else {
            self.services.library.reportOpenFailure()
            return
        }
        // The form is built before anything is presented, so a failure presents nothing.
        let home = self.makeAddHome(meal: LibraryViewModel.mealLabel(for: template))
        let model: AddIntakeViewModel
        do {
            model = try home.makeDetails(prefill: template, now: Date())
        } catch {
            self.services.library.reportOpenFailure()
            return
        }
        self.addNavigation.reset()
        self.addFlowError = nil
        self.addHome = home
        self.addIntakeModel = model
        self.addNavigation.path.append(.details(AddPrefill(model: model)))
    }

    private func openProductDetails(_ product: CustomProductRevision, home: AddHomeViewModel) {
        do { try addNavigation.openProduct(product, home: home, now: Date()); services.library.load() }
        catch { addFlowError = "Could not open product details." }
    }
    private func startProductDetails(_ product: CustomProductRevision) {
        startAddingIntake()
        if let home = addHome { openProductDetails(product, home: home) }
    }
    private func openProductEditor(home: AddHomeViewModel, revision: CustomProductRevision? = nil, legacy: LegacyCustomProductDraft? = nil) {
        let editor = CustomProductEditorViewModel(store: services.journalStore, revision: revision, legacy: legacy, sharing: services.productSharing)
        addNavigation.path.append(.productEditor(ProductEditorPrefill(model: editor)))
    }
    private func startProductEditor(revision: CustomProductRevision? = nil, legacy: LegacyCustomProductDraft? = nil) {
        startAddingIntake()
        if let home = addHome { openProductEditor(home: home, revision: revision, legacy: legacy) }
    }
    private func startProductSearch() {
        startAddingIntake()
        if let home = addHome { openAddRoute(.productSearch, home: home) }
    }

    private func finishAdding() {
        self.addNavigation.reset()
        self.addHome = nil
        self.addIntakeModel = nil
        self.labelCapture = nil
        self.productSearchModel = nil
        self.reload()
    }

    private func openAddRoute(_ route: AddRoute, home: AddHomeViewModel) {
        switch route {
        case .barcodeScanner:
            self.addIntakeModel = home.makeDetails(now: Date())
        case .labelScanner:
            self.labelCapture = LabelCaptureViewModel()
            self.addIntakeModel = home.makeDetails(now: Date())
        case .details:
            self.addIntakeModel = home.makeDetails(now: Date())
        case .productSearch:
            self.productSearchModel = CommunityProductSearchViewModel(store: services.journalStore, service: services.productService,
                openFoodFacts: services.productNameSearch, isSignedIn: { services.account?.phase == .signedIn })
        case .productEditor, .library: break
        }
        self.addNavigation.path.append(route)
    }

    private func pushLabelScanner(keeping model: AddIntakeViewModel) {
        self.addIntakeModel = model
        self.labelCapture = LabelCaptureViewModel()
        self.addNavigation.path.append(.labelScanner)
    }

    /// Opens the details form prefilled from a favorite or recent picked in Add. Nothing is logged until Save.
    private func openTemplate(_ template: RepeatTemplate, home: AddHomeViewModel) {
        // The picker and Find products share this message: one screen's failure must not show on the other.
        self.addFlowError = nil
        do {
            let model = try home.makeDetails(prefill: template, now: Date())
            // A meal chosen on Add wins. With none chosen (Find products opened from the Library tab starts
            // with none), the item keeps the meal it was logged under, as a tap in the Library does.
            if home.meal == nil { model.meal = LibraryViewModel.mealLabel(for: template) }
            self.addIntakeModel = model
            self.addNavigation.path.append(.details(AddPrefill(model: model)))
        } catch {
            self.addFlowError = "Could not open this item. Its saved product may no longer be available."
        }
    }

    @ViewBuilder
    private func addDestination(_ route: AddRoute, home: AddHomeViewModel) -> some View {
        switch route {
        case .barcodeScanner:
            if let model = self.addIntakeModel {
                AddBarcodeDestination(model: model,
                    onScanned: { barcode in
                        await home.scannedBarcode(barcode, into: model)
                    },
                    onFound: { self.addNavigation.path.append(.details(AddPrefill(model: model))) },
                    onLabel: { self.pushLabelScanner(keeping: model) },
                    onType: { self.addNavigation.path.append(.details(AddPrefill(model: model))) })
            }
        case .labelScanner:
            if let capture = self.labelCapture, let model = self.addIntakeModel {
                LabelCaptureSheet(model: capture) { product in
                    model.applyLabelProduct(product, fromLabelCapture: true)
                    self.addNavigation.path.append(.details(AddPrefill(model: model)))
                }
            }
        case .library:
            AddLibraryPicker(library: self.services.library, recipes: self.recipeList,
                onPick: { self.openTemplate($0, home: home) }, onRecipe: { item in
                    do {
                        guard let version = try self.services.recipeStore.version(
                            recipeID: item.id, number: item.versionNumber) else {
                            self.addFlowError = "This recipe is no longer available."
                            return
                        }
                        let model = try home.makeDetails(recipe: version, now: Date())
                        self.addIntakeModel = model
                        self.addNavigation.path.append(.details(AddPrefill(model: model)))
                    } catch RecipeError.nothingToLog {
                        self.addFlowError = "No nutrient value is known, so nothing was logged."
                    } catch {
                        self.addFlowError = "Could not read this recipe."
                    }
                }, onProduct: { self.openProductDetails($0, home: home) },
                onSearchProducts: { self.openAddRoute(.productSearch, home: home) })
                .overlay(alignment: .bottom) {
                    if let message = self.addFlowError { InlineNotice(message, tone: .failed) }
                }
        case .productEditor(let editor):
            CustomProductEditorView(model: editor.model, sharing: services.library.productSharing) { product, openDetails in
                services.library.load()
                if openDetails { self.openProductDetails(product, home: home) }
            }
        case .productSearch:
            if let search = productSearchModel {
                CommunityProductSearchView(model: search,
                    onSelect: { self.openProductDetails($0, home: home) },
                    onLegacy: { self.openProductEditor(home: home, legacy: $0) },
                    onSignIn: { self.settingsAfterAdding = true; self.finishAdding() },
                    onOpenFoodFacts: { self.addNavigation.openLookedUp($0, kind: $1, home: home) },
                    library: self.services.library, onPick: { self.openTemplate($0, home: home) })
                    .overlay(alignment: .bottom) {
                        if let message = self.addFlowError { InlineNotice(message, tone: .failed) }
                    }
                    // An item the picker could not open must not read as a failure on this screen.
                    .onAppear { self.addFlowError = nil }
            }
        case .details(let prefill):
            if let model = prefill?.model ?? self.addIntakeModel {
                AddIntakeView(model: model, now: { Date() },
                    onSaved: { self.finishAdding() },
                    onScanLabel: home.scannerAvailability.label ? {
                        self.pushLabelScanner(keeping: model)
                    } : nil)
            }
        }
    }

    /// The recipes screen, in its own navigation stack so the recipe screens push over each other
    /// without adding a tab. Personal only: nothing here is shared or synced.
    private var recipesSheet: some View {
        NavigationStack(path: $recipeNavigation.path) {
            RecipeListView(
                model: recipeList,
                onNew: { recipeNavigation.path.append(.editor(nil)) },
                onOpen: { item in
                    if let version = try? services.recipeStore.version(
                        recipeID: item.id, number: item.versionNumber) {
                        recipeNavigation.path.append(.detail(version))
                    }
                }
            )
            .navigationDestination(for: RecipeRoute.self) { route in
                switch route {
                case .detail(let version):
                    RecipeDetailView(
                        model: RecipeDetailViewModel(version: version, journal: services.journalStore),
                        now: { Date() },
                        onEdit: { recipeNavigation.path.append(.editor(version)) },
                        onLogged: { reload() }
                    )
                case .editor(let version):
                    RecipeEditorView(
                        model: RecipeEditorViewModel(store: services.recipeStore, editing: version),
                        now: { Date() },
                        onSaved: {
                            // Back to the list: a detail screen would still hold the version it
                            // was opened with, and saving writes a new one.
                            recipeNavigation.path = []
                            recipeList.load()
                        }
                    )
                }
            }
        }
    }

    /// Opens the recipes screen from a clean stack.
    private func openRecipes() {
        recipeNavigation.open()
    }

    /// The journal row being edited, or nil when nothing is open.
    private var detailSheetPresented: Binding<Bool> {
        Binding(
            get: { selectedIntakeID != nil },
            set: { isPresented in
                if !isPresented { selectedIntakeID = nil }
            })
    }

    private func reload(now: Date = Date()) {
        services.today.load(now: now)
        services.journal.load(now: now)
        services.library.load()
        services.firstDayChecklist.load()
        Task { await services.bodyActivity.load(now: now) }
        deliverToHealthKit(now: now)
    }

    /// Runs one HealthKit delivery pass. It does nothing until the person has connected Apple Health
    /// in Settings: an automatic run waits for Health to have been asked about every mapped type.
    ///
    /// Called wherever the journal may have changed — the app coming to the foreground, an add, an
    /// edit, a delete, a restore, an erase — because `reload()` is already the point every one of those
    /// goes through. That is also why there is no timer: a queue that changed is delivered as it
    /// changes, and a retry that is not due yet is left to the next foreground rather than polled.
    private func deliverToHealthKit(now: Date = Date()) {
        Task { await healthKitDeliveryStatus.run(now: now, automatic: true) }
    }
}

/// Shown when a store file cannot be opened at all.
struct StartupFailureView: View {
    let message: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("The app's storage could not be opened.").font(.headline)
            Text(message ?? "Quit the app and try again; if it keeps failing, reinstall the app.")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
