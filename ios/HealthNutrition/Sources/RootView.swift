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
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    // One runner for the app's lifetime, so the transcript survives tab switches.
    @State private var healthKitSpike = HealthKitSpikeRunner()
    #endif

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

            LibraryView(model: services.library, onAdded: { reload() })
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(AppTab.library)

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
                model: AddIntakeViewModel(store: services.journalStore, now: Date()),
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
