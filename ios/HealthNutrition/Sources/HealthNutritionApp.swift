import SwiftUI

/// The HealthNutrition app.
///
/// One journal store, one favorites store and one recipe store are created here, for the app's
/// lifetime, and shared with every screen (see `docs/journal-store.md`). The only network access is
/// the barcode lookup a user asks for in Add intake; there is no HealthKit access in this target yet.
@MainActor
@main
struct HealthNutritionApp: App {
    @State private var services: AppServices?
    @State private var startupError: String?

    init() {
        do {
            _services = State(initialValue: try AppServices.make(reminderScheduler: SystemReminderScheduler()))
        } catch {
            _services = State(initialValue: nil)
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let services {
                RootView(services: services)
            } else {
                StartupFailureView(message: startupError)
            }
        }
    }
}
