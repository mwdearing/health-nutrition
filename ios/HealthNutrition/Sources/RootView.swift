import Foundation
import SwiftUI
import NutritionJournal
import NutritionUI

/// The tab shell: Today, Journal and Library, all reading the same store.
@MainActor
struct RootView: View {
    let services: AppServices

    @State private var selection: AppTab = .today
    @State private var addingIntake = false
    @State private var selectedIntakeID: String?
    @State private var showingRecipes = false
    @State private var recipePath: [RecipeRoute] = []
    @State private var recipeList: RecipeListViewModel
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    // One runner for the app's lifetime, so the transcript survives tab switches.
    @State private var healthKitSpike = HealthKitSpikeRunner()
    #endif

    /// Where the recipe screens navigate to inside their own stack.
    private enum RecipeRoute: Hashable {
        case detail(RecipeVersion)
        /// nil while creating a new recipe, a version while editing one.
        case editor(RecipeVersion?)
    }

    init(services: AppServices) {
        self.services = services
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
                    onAddIntake: { addingIntake = true },
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

            LibraryView(model: services.library, onAdded: { reload() }, onOpenRecipes: { openRecipes() })
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(AppTab.library)
                .sheet(isPresented: $showingRecipes) {
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
        .sheet(isPresented: $addingIntake) {
            AddIntakeView(
                model: AddIntakeViewModel(
                    store: services.journalStore, now: Date(), lookup: services.barcodeLookup
                ),
                now: { Date() },
                onSaved: {
                    addingIntake = false
                    reload()
                },
                onFromLibrary: {
                    addingIntake = false
                    selection = .library
                }
            )
        }
    }

    /// The recipes screen, in its own navigation stack so the recipe screens push over each other
    /// without adding a tab. Personal only: nothing here is shared or synced.
    private var recipesSheet: some View {
        NavigationStack(path: $recipePath) {
            RecipeListView(
                model: recipeList,
                onNew: { recipePath.append(.editor(nil)) },
                onOpen: { item in
                    if let version = try? services.recipeStore.version(
                        recipeID: item.id, number: item.versionNumber) {
                        recipePath.append(.detail(version))
                    }
                }
            )
            .navigationDestination(for: RecipeRoute.self) { route in
                switch route {
                case .detail(let version):
                    RecipeDetailView(
                        model: RecipeDetailViewModel(version: version, journal: services.journalStore),
                        now: { Date() },
                        onEdit: { recipePath.append(.editor(version)) },
                        onLogged: { reload() }
                    )
                case .editor(let version):
                    RecipeEditorView(
                        model: RecipeEditorViewModel(store: services.recipeStore, editing: version),
                        now: { Date() },
                        onSaved: {
                            // Back to the list: a detail screen would still hold the version it
                            // was opened with, and saving writes a new one.
                            recipePath = []
                            recipeList.load()
                        }
                    )
                }
            }
        }
    }

    /// Opens the recipes screen from a clean stack.
    private func openRecipes() {
        recipePath = []
        showingRecipes = true
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
