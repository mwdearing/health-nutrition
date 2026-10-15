import Foundation

/// The running app's services, for the system entry points (App Intents) that start in the app's own
/// process and have no view tree to receive them from.
///
/// Set once by the app at launch. An entry point that runs before it is set, or in a build that failed to
/// open its stores, finds nil and says so rather than writing anywhere else: there is only ever one store.
@MainActor
enum AppServicesRegistry {
    private(set) static var current: AppServices?

    static func register(_ services: AppServices) {
        current = services
    }

    /// True while Erase all data runs or a journal import (restore) has not finished publishing. A shortcut writes
    /// nothing then, so an entry cannot land in a store that is being emptied or filled.
    ///
    /// Read through `canExport`, which holds for as long as any import completion is outstanding, rather than
    /// `isImporting`: leaving Settings clears `isImporting` while a restore may still be writing.
    static var isBusy: Bool {
        guard let connections = current?.connections else { return false }
        return !connections.canExport
    }

    /// Posted after a shortcut wrote an entry, so the app reloads Today, the Diary and the Library and runs a
    /// Health delivery pass exactly as it does after an add in the app (RootView listens for it).
    static let journalWrittenByShortcut = Notification.Name("HealthNutrition.journalWrittenByShortcut")

    static func announceJournalWrite() {
        NotificationCenter.default.post(name: journalWrittenByShortcut, object: nil)
    }
}
