import AppIntents
import Foundation

/// What logging water from a shortcut says back, kept apart from the intent so it can be tested.
enum WaterShortcut {
    struct Outcome: Equatable {
        let logged: Bool
        let message: String
    }

    static let loggedMessage = "Added your usual water to today's diary."
    static let failedMessage = "Could not save the water."
    static let notReadyMessage = "Open the app once, then try again."

    /// - Parameter add: writes one water entry of the person's usual amount at the given time. Returns nil
    ///   when the app's services are not available, false when the write failed.
    static func log(now: Date, add: (Date) -> Bool?) -> Outcome {
        switch add(now) {
        case .some(true): return Outcome(logged: true, message: loggedMessage)
        case .some(false): return Outcome(logged: false, message: failedMessage)
        case .none: return Outcome(logged: false, message: notReadyMessage)
        }
    }
}

/// "Log water" for Siri, Spotlight and the Shortcuts app: one tap adds the usual amount to today's diary.
///
/// It opens the app and uses the app's own store, so there is a single writer and the entry goes through the
/// same path, queueing and undo window as the Today button. Nothing leaves the device because of it.
struct LogWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Log water"
    static let description = IntentDescription("Adds your usual amount of water to today's diary.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WaterShortcut.log(now: Date()) { now in
            guard let services = AppServicesRegistry.current else { return nil }
            return services.today.quickAddWater(now: now) != nil
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct HealthNutritionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogWaterIntent(),
            phrases: ["Log water in \(.applicationName)", "Add water in \(.applicationName)"],
            shortTitle: "Log water",
            systemImageName: "drop")
        AppShortcut(
            intent: LogSavedMealIntent(),
            phrases: ["Log a saved meal in \(.applicationName)", "Add a saved meal in \(.applicationName)"],
            shortTitle: "Log saved meal",
            systemImageName: "fork.knife")
    }
}
