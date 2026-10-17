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
    @State private var services: AppServices?
    @State private var startupError: String?
    /// Keeps the Today widgets' summary current. Held for the app's lifetime.
    private static let widgetSnapshots = WidgetSnapshotPublisher()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--privacy-shield-test") {
            _services = State(initialValue: nil)
            _startupError = State(initialValue: nil)
            return
        }
        #endif
        do {
            let made = try AppServices.make(reminderScheduler: SystemReminderScheduler())
            AppServicesRegistry.register(made)
            Self.widgetSnapshots.start(today: made.today, isErasing: { made.connections.isErasing })
            _services = State(initialValue: made)
        } catch {
            _services = State(initialValue: nil)
            _startupError = State(initialValue: error.localizedDescription)
        }
        // Hands the app's shortcuts to the system at every launch, so Siri and Spotlight offer the current set,
        // a shortcut added in an update included. No phrase names a saved meal, so a changed list needs no
        // refresh: the shortcut reads the list each time it runs.
        HealthNutritionShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--privacy-shield-test") {
                PrivacyShieldCaptureHost()
            } else if let services {
                RootView(services: services)
            } else {
                StartupFailureView(message: startupError)
            }
            #else
            if let services {
                RootView(services: services)
            } else {
                StartupFailureView(message: startupError)
            }
            #endif
        }
    }
}
