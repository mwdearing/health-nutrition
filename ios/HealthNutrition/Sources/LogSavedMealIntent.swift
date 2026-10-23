import AppIntents
import Foundation
import NutritionJournal
import NutritionUI
import UIKit

/// What logging a saved meal from a shortcut says back, kept apart from the intent so it can be tested.
enum SavedMealShortcut {
    struct Outcome: Equatable {
        let logged: Bool
        let message: String
    }

    static let notReadyMessage = WaterShortcut.notReadyMessage
    static let noSavedMealsMessage = "You have no saved meals yet. Save one from a meal in the Diary."
    static let unavailableMessage = SavedMealError.notFound.message
    /// Said instead of logging while an erase or an import runs; nothing is written (#480).
    static let busyMessage = "The app is busy with an erase or import. Try again in a moment."

    /// The reply that stops a run before any write when the app is busy, or nil when the run may go on.
    static func busyReply(isBusy: Bool) -> String? {
        isBusy ? busyMessage : nil
    }

    /// Whether the shortcut has to ask which saved meal: it named none and there are some to choose from. With
    /// none saved, or the list unavailable, `log` answers instead, so its reply is what the person hears.
    static func needsSavedMeal(id: String?, meals: [SavedMeal]?) -> Bool {
        id == nil && !(meals ?? []).isEmpty
    }

    /// Everything a run of the shortcut reads or writes, passed in so the order can be tested with counts.
    struct Effects {
        var isBusy: () -> Bool
        var readMeals: () -> (meals: [SavedMeal]?, loadError: String?)
        var logMeal: (SavedMeal, MealLabel?, Date) throws -> SavedMealLogResult
        var recordLeftovers: ([String]) -> Void
        var reload: (Date) -> Void
    }

    enum RunOutcome: Equatable {
        case reply(String)
        /// The shortcut named no meal and there are several to choose from: the caller asks which.
        case needsSavedMeal
    }

    /// The whole run in order: the busy check first, then the reads, then the write, then the reload. The busy
    /// check comes before any read or write, so an erase or import running gains nothing (#480).
    static func run(id: String?, meal: MealLabel?, now: Date, effects: Effects) -> RunOutcome {
        if let busy = busyReply(isBusy: effects.isBusy()) { return .reply(busy) }
        let read = effects.readMeals()
        // A list that cannot be read is said to be unreadable, not that there are no saved meals.
        if let error = read.loadError { return .reply(error) }
        if needsSavedMeal(id: id, meals: read.meals) { return .needsSavedMeal }
        let outcome = log(
            id: id, meal: meal, now: now, meals: read.meals,
            log: effects.logMeal, leftovers: effects.recordLeftovers)
        // Whatever was written, the app reloads as it does after an add from its own screens.
        effects.reload(now)
        return .reply(outcome.message)
    }

    /// - Parameters:
    ///   - id: the saved meal the shortcut names, or nil when it names none.
    ///   - meals: the saved meals as stored, or nil when the app's services are not available.
    ///   - log: writes the saved meal's items under the meal given, at the time given.
    ///   - leftovers: told the entries a failed write could not remove again, so the app can warn about them.
    static func log(
        id: String?, meal: MealLabel?, now: Date, meals: [SavedMeal]?,
        log: (SavedMeal, MealLabel?, Date) throws -> SavedMealLogResult, leftovers: ([String]) -> Void = { _ in }
    ) -> Outcome {
        guard let meals else { return Outcome(logged: false, message: notReadyMessage) }
        guard !meals.isEmpty else { return Outcome(logged: false, message: noSavedMealsMessage) }
        guard let id, let saved = meals.first(where: { $0.id == id }) else {
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

/// The saved-meal picker policy, kept apart from the query so it can be tested. The list is offered only while the
/// device is unlocked and no erase or import runs; a locked phone gets no names, and a stored id still resolves.
enum SavedMealPickerPolicy {
    /// The title a shortcut shows while locked or busy: no meal name in it.
    static let standInTitle = "Saved meal"

    /// The entities for an enumeration: the meals while unlocked and not busy, nothing otherwise.
    static func enumerated(_ meals: [SavedMeal], isUnlocked: Bool, isBusy: Bool) -> [SavedMeal] {
        guard !isBusy, isUnlocked else { return [] }
        return meals
    }
}

/// Reads the saved meals straight from their store, so the list is there even before the app has opened.
struct SavedMealQuery: EntityQuery {
    /// The title a shortcut shows for a saved meal deleted since it was set up; running it says the same.
    static let deletedTitle = SavedMealShortcut.unavailableMessage

    @MainActor
    static var isDeviceUnlocked: () -> Bool = { UIApplication.shared.isProtectedDataAvailable }

    @MainActor
    func entities(for identifiers: [SavedMealEntity.ID]) async throws -> [SavedMealEntity] {
        let meals = try? UserDefaultsSavedMealStore().meals()
        let unlocked = Self.isDeviceUnlocked() && !AppServicesRegistry.isBusy
        return Self.entities(for: identifiers, in: meals, revealNames: unlocked)
    }

    @MainActor
    func suggestedEntities() async throws -> [SavedMealEntity] {
        SavedMealPickerPolicy
            .enumerated(
                (try? UserDefaultsSavedMealStore().meals()) ?? [],
                isUnlocked: Self.isDeviceUnlocked(), isBusy: AppServicesRegistry.isBusy)
            .map { SavedMealEntity(id: $0.id, name: $0.name) }
    }

    /// Every id a shortcut names gets an entity, so the action runs and answers for itself: a saved meal deleted
    /// since (or a list that cannot be read) stands in under `deletedTitle` rather than being dropped, which would
    /// leave the shortcut asking for another meal. While locked or busy the real name is held back and the
    /// stand-in title is used, so the shortcut still resolves without showing what was logged.
    static func entities(for identifiers: [String], in meals: [SavedMeal]?, revealNames: Bool) -> [SavedMealEntity] {
        identifiers.map { id in
            guard let meal = meals?.first(where: { $0.id == id }) else {
                return SavedMealEntity(id: id, name: deletedTitle)
            }
            return SavedMealEntity(id: meal.id, name: revealNames ? meal.name : SavedMealPickerPolicy.standInTitle)
        }
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
    /// Running the action, and so logging the meal, needs an unlocked device. The saved meal names are not listed
    /// while locked (SavedMealPickerPolicy and SavedMealQuery); a stored id still resolves and then reaches this
    /// requirement, so the system asks for the unlock before anything is read or written.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    /// Optional, so the action runs when there are no saved meals, or the one a shortcut names was deleted, and
    /// says so; with saved meals to choose from and none named, it asks for one.
    @Parameter(title: "Saved meal")
    var savedMeal: SavedMealEntity?

    @Parameter(title: "Meal", description: "Leave empty to use the meal it was saved with.")
    var meal: ShortcutMeal?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServicesRegistry.current
        let effects = SavedMealShortcut.Effects(
            isBusy: { AppServicesRegistry.isBusy },
            readMeals: {
                guard let services else { return (nil, nil) }
                services.savedMeals.load()
                return (services.savedMeals.meals, services.savedMeals.loadError)
            },
            logMeal: { saved, meal, now in
                guard let services else { throw SavedMealError.notFound }
                // As a log from the screen does, an earlier Undo offer is dropped first, so Undo in the app never
                // names a meal logged before this one.
                services.savedMeals.clearUndo()
                return try SavedMealLogger(store: services.journalStore).log(saved, as: meal, now: now)
            },
            recordLeftovers: { ids in services?.savedMeals.recordLeftovers(ids) },
            reload: { now in if let services { Self.reload(services, now: now) } })
        switch SavedMealShortcut.run(id: savedMeal?.id, meal: meal?.label, now: Date(), effects: effects) {
        case .needsSavedMeal:
            throw $savedMeal.needsValueError()
        case .reply(let message):
            return .result(dialog: IntentDialog(stringLiteral: message))
        }
    }

    /// What `RootView.reload()` does after an add: every screen that lists entries reads again, and one
    /// Apple Health delivery pass runs (it does nothing until Apple Health is connected).
    @MainActor
    private static func reload(_ services: AppServices, now: Date) {
        services.today.load(now: now)
        services.journal.load(now: now)
        services.library.load()
        services.firstDayChecklist.load()
        Task { await services.healthKitDeliveryStatus.run(now: now, automatic: true) }
    }
}
