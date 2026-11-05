import AppIntents
import SwiftUI

/// The HealthNutrition app.
///
/// One journal store, one favorites store and one recipe store are created here, for the app's
/// lifetime, and shared with every screen (see `docs/journal-store.md`). The network access is the barcode
/// lookup a user asks for in Add intake and, in a build with the project settings, the account calls a person
/// makes after signing in; there is no HealthKit access in this target yet.
@MainActor
@main
struct HealthNutritionApp: App {
    /// Created in `init`, so the stores are opened and registered at launch, before any scene exists.
    @State private var startup: AppStartup
    /// Keeps the Today widgets' summary current. Held for the app's lifetime.
    private static let widgetSnapshots = WidgetSnapshotPublisher()
    /// Opens the services once per process. SwiftUI may run `init` (and so the `State` initial value) more than
    /// once, and only the first `State` value is kept; this makes every later run reuse the opened services
    /// instead of opening the stores and wiring the watch and widget hooks again.
    private static let launch = OpenOnce(open: HealthNutritionApp.wireServices)

    /// Opens the services, or returns the ones already open. Run at launch, and again by Try again after a failed
    /// launch, so a transient failure (a busy or locked file) does not need a force-quit.
    private static func openServices() throws -> AppServices {
        try launch.open()
    }

    private static func wireServices() throws -> AppServices {
        let made = try AppServices.make(reminderScheduler: SystemReminderScheduler())
        AppServicesRegistry.register(made)
        widgetSnapshots.start(today: made.today, isErasing: { made.connections.isErasing })
        WatchSessionTransport.shared.onReady = { WatchSnapshotSender.shared.transportBecameReady() }
        WatchSnapshotSender.shared.resumeAfterLaunch()
        WatchSessionTransport.shared.activate()
        return made
    }

    init() {
        _startup = State(initialValue: AppStartup(open: Self.openServices))
        // Hands the app's shortcuts to the system at every launch, so Siri and Spotlight offer the current set,
        // a shortcut added in an update included. No phrase names a saved meal, so a changed list needs no
        // refresh: the shortcut reads the list each time it runs.
        HealthNutritionShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            LaunchView(startup: startup)
        }
    }
}

/// Runs `make` until it succeeds, then returns that result for every later call. A failure is not remembered, so
/// a later call tries again.
@MainActor
final class OpenOnce {
    private let make: () throws -> AppServices
    private var opened: AppServices?

    init(open make: @escaping () throws -> AppServices) {
        self.make = make
    }

    func open() throws -> AppServices {
        if let opened { return opened }
        let made = try make()
        opened = made
        return made
    }
}

/// RootView once the services are open; otherwise the failure screen with its Try again.
private struct LaunchView: View {
    @ObservedObject var startup: AppStartup

    var body: some View {
        if let services = startup.services {
            RootView(services: services)
        } else {
            StartupFailureView(message: startup.failure, onRetry: { startup.attempt() })
        }
    }
}

/// Opens the app's services at launch and again on request. The failure text is kept for the failure screen.
@MainActor
final class AppStartup: ObservableObject {
    @Published private(set) var services: AppServices?
    @Published private(set) var failure: String?
    private let open: () throws -> AppServices

    init(open: @escaping () throws -> AppServices) {
        self.open = open
        attempt()
    }

    /// Tries to open the services. A failed try leaves the failure text for the screen; a later success clears it.
    func attempt() {
        guard services == nil else { return }
        do {
            services = try open()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
