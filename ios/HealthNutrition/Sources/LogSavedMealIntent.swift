import AppIntents
import Foundation
import NutritionJournal
import NutritionUI

/// What logging a saved meal from a shortcut says back, kept apart from the intent so it can be tested.
enum SavedMealShortcut {
    struct Outcome: Equatable {
        let logged: Bool
        let message: String
    }

    static let notReadyMessage = WaterShortcut.notReadyMessage
    static let noSavedMealsMessage = "You have no saved meals yet. Save one from a meal in the Diary."
    static let unavailableMessage = SavedMealError.notFound.message

    /// - Parameters:
    ///   - meals: the saved meals as stored, or nil when the app's services are not available.
    ///   - log: writes the saved meal's items under the meal given, at the time given.
    ///   - leftovers: told the entries a failed write could not remove again, so the app can warn about them.
    static func log(
        id: String, meal: MealLabel?, now: Date, meals: [SavedMeal]?,
        log: (SavedMeal, MealLabel?, Date) throws -> SavedMealLogResult, leftovers: ([String]) -> Void = { _ in }
    ) -> Outcome {
        guard let meals else { return Outcome(logged: false, message: notReadyMessage) }
        guard !meals.isEmpty else { return Outcome(logged: false, message: noSavedMealsMessage) }
        guard let saved = meals.first(where: { $0.id == id }) else {
            return Outcome(logged: false, message: unavailableMessage)
        }
        do {
            // A meal named in the shortcut wins; with none, the meal it was saved with.
            let result = try log(saved, meal ?? saved.meal, now)
            return Outcome(logged: result.loggedCount > 0, message: message(for: result, name: saved.name))
        } catch let partial as SavedMealPartialLogError {
            // Some entries stayed after the failed write, so the reply does not say nothing was logged.
            leftovers(partial.remainingIDs)
            return Outcome(logged: false, message: "Could not add \(saved.name).")
        } catch {
            return Outcome(logged: false, message: "Could not add \(saved.name). Nothing was logged.")
        }
    }

    static func message(for result: SavedMealLogResult, name: String) -> String {
        guard result.loggedCount > 0 else {
            return "Nothing was added: \(itemsText(result.skippedCount)) can no longer be logged."
        }
        guard result.skippedCount > 0 else { return "Added \(name) to today's diary." }
        let total = result.loggedCount + result.skippedCount
        return "Added \(result.loggedCount) of \(total) items of \(name) to today's diary. "
            + "\(itemsText(result.skippedCount)) can no longer be logged."
    }

    private static func itemsText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

/// A saved meal as Siri and the Shortcuts app offer it.
struct SavedMealEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved meal"
    static let defaultQuery = SavedMealQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Reads the saved meals straight from their store, so the list is there even before the app has opened.
struct SavedMealQuery: EntityQuery {
    func entities(for identifiers: [SavedMealEntity.ID]) async throws -> [SavedMealEntity] {
        Self.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SavedMealEntity] {
        Self.all()
    }

    private static func all() -> [SavedMealEntity] {
        ((try? UserDefaultsSavedMealStore().meals()) ?? []).map { SavedMealEntity(id: $0.id, name: $0.name) }
    }
}

/// The meals a shortcut can log a saved meal under.
enum ShortcutMeal: String, AppEnum {
    case breakfast, lunch, dinner, snack

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"
    static let caseDisplayRepresentations: [ShortcutMeal: DisplayRepresentation] = [
        .breakfast: "Breakfast", .lunch: "Lunch", .dinner: "Dinner", .snack: "Snack",
    ]

    var label: MealLabel? { MealLabel(rawValue: rawValue) }
}

/// "Log a saved meal" for Siri, Spotlight and the Shortcuts app: every item of one saved meal, now.
///
/// It opens the app and logs through the app's own journal store, so there is a single writer and each entry
/// is an ordinary one, written to Apple Health once that is connected. There is no Undo here; the entries can
/// be deleted in the Diary like any other.
struct LogSavedMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a saved meal"
    static let description = IntentDescription("Adds every item of one of your saved meals to today's diary, as new entries.")
    static let openAppWhenRun = true

    @Parameter(title: "Saved meal")
    var savedMeal: SavedMealEntity

    @Parameter(title: "Meal", description: "Leave empty to use the meal it was saved with.")
    var meal: ShortcutMeal?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServicesRegistry.current
        let meals: [SavedMeal]?
        if let services {
            services.savedMeals.load()
            // A list that cannot be read is said to be unreadable, not that there are no saved meals.
            if let error = services.savedMeals.loadError {
                return .result(dialog: IntentDialog(stringLiteral: error))
            }
            meals = services.savedMeals.meals
        } else {
            meals = nil
        }
        let outcome = SavedMealShortcut.log(
            id: savedMeal.id, meal: meal?.label, now: Date(), meals: meals,
            log: { saved, meal, now in
                guard let services else { throw SavedMealError.notFound }
                let result = try SavedMealLogger(store: services.journalStore).log(saved, as: meal, now: now)
                services.today.load(now: now)
                services.journal.load(now: now)
                return result
            },
            leftovers: { ids in services?.savedMeals.recordLeftovers(ids) })
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}
