import Foundation
import NutritionJournal
import NutritionUI

/// The stores and view models the app runs on.
///
/// The journal store holds a write lock per instance, so the app creates exactly one store per
/// database file and keeps it for its whole lifetime (see `docs/journal-store.md`). Favorites
/// live in a second file next to the journal file.
@MainActor
final class AppServices {
    let journalStore: SwiftDataJournalStore
    let favoritesStore: SwiftDataFavoritesStore

    let today: TodayViewModel
    let journal: JournalViewModel
    let library: LibraryViewModel

    private init(journalStore: SwiftDataJournalStore, favoritesStore: SwiftDataFavoritesStore) {
        self.journalStore = journalStore
        self.favoritesStore = favoritesStore
        today = TodayViewModel(store: journalStore)
        journal = JournalViewModel(store: journalStore)
        library = LibraryViewModel(store: journalStore, favorites: favoritesStore)
    }

    /// Opens both store files in `directory`, creating them if needed.
    static func make() throws -> AppServices {
        let directory = defaultDirectory
        let journalStore = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        do {
            let favoritesStore = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
            return AppServices(journalStore: journalStore, favoritesStore: favoritesStore)
        } catch {
            journalStore.close()
            throw error
        }
    }

    /// Application Support/HealthNutrition, created on first use.
    static var defaultDirectory: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthNutrition", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
