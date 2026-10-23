import AppIntents
import Foundation
import NutritionUI
import UIKit

/// One item on the supplement list as a shortcut needs it: which it is and the times still open today.
struct ShortcutSupplement: Equatable {
    let id: String
    let title: String
    /// Today's times that are not taken yet, each of which has a per-time Taken button on the list. Empty on a
    /// day off the schedule or with every time taken, where the list logs one Taken that marks no time.
    let openTimes: [ReminderTime]
}

/// The supplement list as the shortcut needs it. The list's view model conforms, so a shortcut records a
/// Taken through the same call the list's own per-time button makes, and a test can pass a fake.
@MainActor
protocol SupplementTakenLogging: AnyObject {
    var items: [ShortcutSupplement] { get }
    var refusalMessage: String? { get }
    func load(now: Date)
    func markTaken(id: String, at time: ReminderTime?, now: Date) -> Bool
}

extension SupplementStackViewModel: SupplementTakenLogging {
    var items: [ShortcutSupplement] {
        rows.map { row in
            ShortcutSupplement(
                id: row.id, title: row.title, openTimes: row.slots.filter { $0.state != .taken }.map(\.time))
        }
    }

    var refusalMessage: String? { errorMessage }

    func markTaken(id: String, at time: ReminderTime?, now: Date) -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else { return false }
        return markTaken(row, at: time, now: now)
    }
}

/// What logging a supplement as taken from a shortcut does and says back, kept apart from the intent so it
/// can be tested.
enum SupplementShortcut {
    struct Outcome: Equatable {
        let logged: Bool
        let message: String
    }

    static let emptyListMessage = "Add a supplement to your list first."
    static let notReadyMessage = "Open the app once, then try again."
    static let notOnListMessage = "This item is no longer on your supplements."
    static let failedMessage = "Could not log it. Try again."

    static func loggedMessage(_ title: String) -> String { "Logged \(title)" }

    /// The open time closest to when the shortcut runs, by time of day in `calendar`'s zone: at 9 PM with 8 AM and
    /// 8 PM open that is 8 PM, at 11 AM it is 8 AM. A tie goes to the earlier time, the one that has already
    /// passed. Nil when no time is open.
    static func nearestOpenTime(in times: [ReminderTime], to now: Date, calendar: Calendar) -> ReminderTime? {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let current = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return times.min { first, second in
            let a = abs(first.hour * 60 + first.minute - current)
            let b = abs(second.hour * 60 + second.minute - current)
            if a != b { return a < b }
            return first.hour * 60 + first.minute < second.hour * 60 + second.minute
        }
    }

    /// Logs one Taken for the item with this id.
    ///
    /// - Parameter stack: the supplement list, or nil when the app's services are unavailable.
    /// - Parameter isErasing: true while Erase all data or a restore runs. Nothing is written then, so a
    ///   Taken cannot land in a store that is being emptied.
    @MainActor
    static func log(
        favoriteID: String, now: Date, stack: (any SupplementTakenLogging)?, isErasing: Bool = false,
        calendar: Calendar = .current
    ) -> Outcome {
        guard let stack else { return Outcome(logged: false, message: notReadyMessage) }
        guard !isErasing else { return Outcome(logged: false, message: failedMessage) }
        stack.load(now: now)
        let items = stack.items
        guard !items.isEmpty else {
            // A list that could not be read is empty too; its own reason is the honest answer then.
            return Outcome(logged: false, message: stack.refusalMessage ?? emptyListMessage)
        }
        guard let item = items.first(where: { $0.id == favoriteID }) else {
            return Outcome(logged: false, message: notOnListMessage)
        }
        let time = nearestOpenTime(in: item.openTimes, to: now, calendar: calendar)
        if stack.markTaken(id: item.id, at: time, now: now) {
            return Outcome(logged: true, message: loggedMessage(item.title))
        }
        // The list's own refusal text ("This item has no amounts to log." and the like) is what the screen shows.
        return Outcome(logged: false, message: stack.refusalMessage ?? failedMessage)
    }
}

/// One item on the supplement list, offered to Shortcuts and Siri by its title.
struct SupplementEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Supplement"
    static let defaultQuery = SupplementEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// Which items of the supplement list the picker and Siri may be told about.
enum SupplementPickerPolicy {
    /// The title a saved shortcut gets while locked or for an item no longer on the list: the existing word, with
    /// no name in it.
    static let standInTitle = "Supplement"

    /// The entity list for an enumeration (the picker, Siri's prompts): the items while the device is unlocked,
    /// nothing while it is locked or busy (Erase all data or an import running).
    static func enumerated(_ items: [ShortcutSupplement], isUnlocked: Bool, isBusy: Bool) -> [ShortcutSupplement] {
        guard !isBusy, isUnlocked else { return [] }
        return items
    }

    /// The entities for the ids a saved shortcut stores: one per requested id, so the saved shortcut always
    /// resolves and then reaches the unlock requirement and the action's own messages. The real title only
    /// while unlocked and the item is on the list; otherwise the stand-in title.
    static func resolved(
        _ items: [ShortcutSupplement], identifiers: [String], isUnlocked: Bool, isBusy: Bool
    ) -> [(id: String, title: String)] {
        identifiers.map { id in
            guard !isBusy, isUnlocked, let item = items.first(where: { $0.id == id }) else {
                return (id, standInTitle)
            }
            return (id, item.title)
        }
    }
}

struct SupplementEntityQuery: EntityQuery {
    @MainActor
    static var isDeviceUnlocked: () -> Bool = { UIApplication.shared.isProtectedDataAvailable }

    /// Whether a list read may run at all: only while the device is unlocked and no erase or restore is running.
    /// The picker policy already gives no names in that state, so reading first would only do the list's tidy
    /// writes for a request that is then answered with nothing.
    static func readsTheList(isUnlocked: Bool, isBusy: Bool) -> Bool {
        isUnlocked && !isBusy
    }

    @MainActor
    private func loadedItems() -> [ShortcutSupplement] {
        guard let services = AppServicesRegistry.current,
            Self.readsTheList(isUnlocked: Self.isDeviceUnlocked(), isBusy: AppServicesRegistry.isBusy)
        else { return [] }
        let stack = services.supplementStack
        stack.load(now: Date())
        return stack.items
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SupplementEntity] {
        SupplementPickerPolicy
            .resolved(
                loadedItems(), identifiers: identifiers, isUnlocked: Self.isDeviceUnlocked(),
                isBusy: AppServicesRegistry.isBusy)
            .map { SupplementEntity(id: $0.id, title: $0.title) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SupplementEntity] {
        SupplementPickerPolicy
            .enumerated(loadedItems(), isUnlocked: Self.isDeviceUnlocked(), isBusy: AppServicesRegistry.isBusy)
            .map { SupplementEntity(id: $0.id, title: $0.title) }
    }
}

/// "Log supplement taken" for Siri, Spotlight and Shortcuts: records one Taken for a supplement on the list.
///
/// It opens the app and uses the app's own supplement list, so there is one writer and the entry is an
/// ordinary one with the same time mark and Apple Health queueing as the list's Taken button; the app reloads
/// its screens and runs a Health delivery pass afterwards, and the undo offer lasts the usual ten seconds.
struct LogSupplementTakenIntent: AppIntent {
    static let title: LocalizedStringResource = "Log supplement taken"
    static let description = IntentDescription("Marks a supplement from your list as taken.")
    static let openAppWhenRun = true
    /// Running the action, and so "Logged <supplement>", needs an unlocked device. Choosing an item happens
    /// before this applies, so no list and no name is offered while the device is locked (SupplementPickerPolicy);
    /// a saved shortcut's stored id still resolves, with a stand-in title, and then reaches this requirement.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Supplement", requestValueDialog: "Which supplement?")
    var supplement: SupplementEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$supplement) taken")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServicesRegistry.current
        let outcome = SupplementShortcut.log(
            favoriteID: supplement.id, now: Date(), stack: services?.supplementStack,
            isErasing: AppServicesRegistry.isBusy)
        if outcome.logged, let stack = services?.supplementStack {
            AppServicesRegistry.announceJournalWrite()
            // The undo offer the write created is the list's ten-second one, but nothing here shows the list, so
            // expire it on the same clock rather than leave it for a screen opened hours later.
            if let token = stack.undoToken {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    stack.expireUndo(token)
                }
            }
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}
