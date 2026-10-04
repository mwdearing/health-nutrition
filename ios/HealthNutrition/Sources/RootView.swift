import Foundation
import SwiftUI
import NutritionJournal
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
    @State private var addingIntake = false
    /// Held rather than built inside the sheet, so a scanned barcode can be written into the same
    /// form that will be saved.
    @State private var addIntakeModel: AddIntakeViewModel?
    @State private var scanningBarcode = false
    @State private var capturingLabel = false
    /// Held so the review screen's values go into the same form the entry is saved from, and so a
    /// retake starts from a clean panel.
    @State private var labelCapture: LabelCaptureViewModel?
    @State private var selectedIntakeID: String?
    /// Held rather than kept as plain view state, so the erase below closes the recipe sheet and drops
    /// its routes through one method a test can call.
    @StateObject private var recipeNavigation = RecipeNavigation()
    @State private var recipeList: RecipeListViewModel
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    // One runner for the app's lifetime, so the transcript survives tab switches.
    @State private var healthKitSpike = HealthKitSpikeRunner()
    #endif

    init(services: AppServices) {
        self.services = services
        _connections = ObservedObject(wrappedValue: services.connections)
        _recipeList = State(initialValue: RecipeListViewModel(store: services.recipeStore))
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
                    onOpenJournal: { selection = .journal },
                    onOpenLibrary: { selection = .library }
                )
            }
            .tabItem { Label("Today", systemImage: "sun.max") }
            .tag(AppTab.today)

            JournalView(model: services.journal, onSelect: { selectedIntakeID = $0 })
                .sheet(isPresented: detailSheetPresented) {
                    if let intakeID = selectedIntakeID {
                        EntryDetailView(
                            model: EntryDetailViewModel(store: services.journalStore, intakeID: intakeID),
                            now: { Date() },
                            onFinished: {
                                selectedIntakeID = nil
                                reload()
                            }
                        )
                    }
                }
                .tabItem { Label("Journal", systemImage: "list.bullet") }
                .tag(AppTab.journal)

            LibraryView(
                model: services.library, onAdded: { reload() }, onOpenRecipes: { openRecipes() },
                connections: connections
            )
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(AppTab.library)
                .sheet(isPresented: $recipeNavigation.showingRecipes) {
                    recipesSheet
                }

            #if DEBUG
            // Debug builds only: measures how HealthKit resolves a repeated sync identifier.
            HealthKitSpikeView(runner: healthKitSpike)
                .tabItem { Label("HealthKit", systemImage: "waveform.path.ecg") }
                .tag(AppTab.spike)
            #endif
        }
        // Today's totals depend on the local day: recompute them when the app comes back to the
        // foreground, e.g. after midnight or a time-zone change while it stayed on one tab.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        // An erase on the Connections and privacy screen empties the stores these tabs read, so their
        // held values go with it rather than showing entries that no longer exist.
        .onChange(of: connections.eraseGeneration) { _, _ in
            // A recipe detail or editor holds its own copy of the recipe, so close those routes too:
            // otherwise an erased recipe stays on screen and can still be logged.
            recipeNavigation.reset()
            reload()
            recipeList.load()
        }
        .sheet(isPresented: $addingIntake) {
            if let model = addIntakeModel {
                AddIntakeView(
                    model: model,
                    now: { Date() },
                    onSaved: {
                        addingIntake = false
                        addIntakeModel = nil
                        reload()
                    },
                    onFromLibrary: {
                        addingIntake = false
                        addIntakeModel = nil
                        selection = .library
                    },
                    // nil hides the button, so the form only offers scanning where the device has a
                    // camera that can read barcodes.
                    onScanBarcode: scanBarcode,
                    // Label capture is offered on its own terms: it asks the camera for text rather
                    // than for a code, and it needs no lookup source to be available.
                    onScanLabel: scanLabel
                )
                // The scanner fills the field and closes itself. The lookup still runs only when
                // the user taps Look up.
                .sheet(isPresented: $scanningBarcode) {
                    BarcodeScannerSheet { barcode in
                        // Through the model, so a scan drops whatever an earlier lookup filled in.
                        model.setScannedBarcode(barcode)
                    }
                }
                // The capture sheet owns the camera and the review screen. The values are handed to
                // the form only after the user has confirmed every value the parser was unsure about.
                .sheet(isPresented: $capturingLabel) {
                    if let capture = labelCapture {
                        LabelCaptureSheet(model: capture) { product in
                            // Through the model, so captured values are invalidated by a later barcode
                            // or edit the same way looked-up values are.
                            model.applyLabelProduct(product)
                            labelCapture = nil
                        }
                    }
                }
            }
        }
    }

    /// Opens the intake form with a fresh model, so a scan and the save that follows share one form.
    private func startAddingIntake() {
        addIntakeModel = AddIntakeViewModel(
            store: services.journalStore, now: Date(), lookup: services.barcodeLookup
        )
        addingIntake = true
    }

    /// The action the intake form's Scan button runs. nil where the device cannot scan barcodes,
    /// which hides the button instead of offering something that would not work.
    private var scanBarcode: (() -> Void)? {
        guard BarcodeScanner.isAvailable else { return nil }
        return { scanningBarcode = true }
    }

    /// The action the intake form's Scan label entry runs. nil where the device cannot read text with
    /// the camera, which hides the entry rather than offering something that would not work.
    private var scanLabel: (() -> Void)? {
        guard LabelTextScanner.isAvailable else { return nil }
        return {
            // A fresh view model per capture, so a previous panel is never on screen behind this one.
            labelCapture = LabelCaptureViewModel()
            capturingLabel = true
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
