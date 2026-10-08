import Foundation
import SwiftUI
import NutritionJournal
import NutritionDomain
import NutritionUI

/// The tab shell: Today, Journal and Library, all reading the same store.
@MainActor
struct RootView: View {
    let services: AppServices
    /// Observed rather than reached through `services`, so publishing a change on it re-evaluates this
    /// shell. Reading it through the plain property left the erase handler below waiting for some
    /// unrelated change before it ran, with erased entries still on screen.
    @ObservedObject var connections: ConnectionsPrivacyViewModel

    @State private var selection: AppTab = .today
    @State private var addHome: AddHomeViewModel?
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
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    /// The design-system screenshots run a debug build with `SCREENSHOT_DIR` set. They leave out the
    /// debug-only HealthKit tab and delivery line so the pictures show the app's own screens.
    private static let isCapturingScreenshots = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] != nil
    /// Today's view model, observed so this body is re-evaluated when its values change. Read only for
    /// the water total below, which is the one journal write that does not go through `reload()`.
    @ObservedObject var todayModel: TodayViewModel
    // One runner for the app's lifetime, so the transcript survives tab switches. It is handed the
    // same delivery status the debug section shows, so a request made here reaches the real writer.
    @State private var healthKitSpike: HealthKitSpikeRunner
    // The delivery status the debug section reads and the delivery runs below write into. Held here
    // rather than built in the section, so the counts and the last run's outcome list survive tab
    // switches and are the same state the one-line summary on Today reads.
    @State private var healthKitDeliveryStatus: HealthKitDeliveryStatus
    #endif

    init(services: AppServices) {
        self.services = services
        _connections = ObservedObject(wrappedValue: services.connections)
        _recipeList = State(initialValue: RecipeListViewModel(store: services.recipeStore))
        #if DEBUG
        _todayModel = ObservedObject(wrappedValue: services.today)
        // The app's own worker, not a second one: two workers over one store would each try to deliver
        // the same queued operation.
        let deliveryStatus = HealthKitDeliveryStatus(
            healthKitDelivery: services.healthKitDelivery, store: services.journalStore)
        _healthKitDeliveryStatus = State(initialValue: deliveryStatus)
        _healthKitSpike = State(initialValue: HealthKitSpikeRunner(deliveryStatus: deliveryStatus))
        #endif
    }

    private enum AppTab: Hashable {
        case today
        case journal
        case library
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
                    onAddToMeal: { meal in self.startAddingIntake(meal: meal) }
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
            .tabItem { Label("Today", systemImage: "sun.max") }
            .tag(AppTab.today)

            NavigationStack {
                JournalView(model: services.journal, onSelect: { selectedIntakeID = $0 })
                    .toolbar { settingsToolbar }
            }
                .tabItem { Label("Journal", systemImage: "list.bullet") }
                .tag(AppTab.journal)

            // In a navigation stack like the other two tabs. Settings, goals and the privacy screen are
            // reached from the gear on every tab, not from here.
            NavigationStack {
                LibraryView(
                    model: services.library, onAdded: { reload() }, onOpenRecipes: { openRecipes() }
                )
                .navigationTitle("Library")
                .toolbar { settingsToolbar }
            }
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(AppTab.library)
                .sheet(isPresented: $recipeNavigation.showingRecipes) {
                    recipesSheet
                }

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
        // One Add capsule for the whole shell, above the tab bar on all three tabs. It is the only filled
        // action on screen, and the tab bar stays for navigation.
        .safeAreaInset(edge: .bottom) {
            addCapsule
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
                        }
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
        .sheet(isPresented: $showingSettings, onDismiss: { self.reload() }) {
            NavigationStack {
                AppSettingsView(
                    goals: services.goals, connections: connections, now: { Date() },
                    opensGoals: settingsOpensGoals
                )
            }
        }
        // Today's totals depend on the local day: recompute them when the app comes back to the
        // foreground, e.g. after midnight or a time-zone change while it stayed on one tab.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
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
            services.goals.load()
        }
        #if DEBUG
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
        #endif
        .fullScreenCover(item: $addHome, onDismiss: { self.addNavigation.reset(); self.reload() }) { home in
            NavigationStack(path: self.$addNavigation.path) {
                AddHomeView(
                    model: home,
                    onBarcode: { self.openAddRoute(.barcodeScanner, home: home) },
                    onLabel: { self.openAddRoute(.labelScanner, home: home) },
                    onLibrary: { self.openAddRoute(.library, home: home) },
                    onType: { self.openAddRoute(.details(nil), home: home) },
                    onChanged: { self.reload() }
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

    /// The shared "Add food or drink" capsule, laid over the bottom of every tab.
    private var addCapsule: some View {
        PrimaryCapsule("Add food or drink", systemImage: "plus") {
            startAddingIntake()
        }
        .accessibilityLabel("Add food or drink")
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
        self.addHome = AddHomeViewModel(
            store: self.services.journalStore, meal: meal,
            scannerAvailability: AddScannerAvailability(
                barcode: BarcodeScanner.isAvailable, label: LabelTextScanner.isAvailable),
            lookup: self.services.barcodeLookup, preferences: self.services.displayPreferences)
    }

    private func finishAdding() {
        self.addNavigation.reset()
        self.addHome = nil
        self.addIntakeModel = nil
        self.labelCapture = nil
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
        case .library: break
        }
        self.addNavigation.path.append(route)
    }

    private func pushLabelScanner(keeping model: AddIntakeViewModel) {
        self.addIntakeModel = model
        self.labelCapture = LabelCaptureViewModel()
        self.addNavigation.path.append(.labelScanner)
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
                    model.applyLabelProduct(product)
                    self.addNavigation.path.append(.details(AddPrefill(model: model)))
                }
            }
        case .library:
            AddLibraryPicker(library: self.services.library, recipes: self.recipeList,
                onPick: { template in
                    do {
                        let model = try home.makeDetails(prefill: template, now: Date())
                        self.addIntakeModel = model
                        self.addNavigation.path.append(.details(AddPrefill(model: model)))
                    } catch {
                        self.addFlowError = "Could not open this item. Its saved product may no longer be available."
                    }
                }, onRecipe: { item in
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
                })
                .overlay(alignment: .bottom) {
                    if let message = self.addFlowError { InlineNotice(message, tone: .failed) }
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
        #if DEBUG
        deliverToHealthKit(now: now)
        #endif
    }

    #if DEBUG
    /// Runs one HealthKit delivery pass. Debug builds only: a release build queues nothing for Health,
    /// so there would be nothing to deliver.
    ///
    /// Called wherever the journal may have changed — the app coming to the foreground, an add, an
    /// edit, a delete, a restore, an erase — because `reload()` is already the point every one of those
    /// goes through. That is also why there is no timer: a queue that changed is delivered as it
    /// changes, and a retry that is not due yet is left to the next foreground rather than polled.
    private func deliverToHealthKit(now: Date = Date()) {
        Task { await healthKitDeliveryStatus.run(now: now, automatic: true) }
    }
    #endif
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
