import Foundation
import NutritionJournal
import NutritionProviders
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
    /// Barcode lookups in Add intake. One client for the app's lifetime, so its rolling rate-limit
    /// window is shared and never reset by opening the form again.
    let barcodeLookup: BarcodeProductLookup

    private init(journalStore: SwiftDataJournalStore, favoritesStore: SwiftDataFavoritesStore) {
        self.journalStore = journalStore
        self.favoritesStore = favoritesStore
        today = TodayViewModel(store: journalStore)
        journal = JournalViewModel(store: journalStore)
        library = LibraryViewModel(store: journalStore, favorites: favoritesStore)
        barcodeLookup = OpenFoodFactsProductLookup(
            client: OpenFoodFactsClient(appVersion: Self.appVersion))
    }

    /// The marketing version from the bundle; the provider requires a User-Agent that names the app
    /// and its version. The debug "0" keeps the header well formed before the first build stamp.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Opens both store files in `directory`, creating them if needed.
    static func make() throws -> AppServices {
        let directory = defaultDirectory
        // No delivery worker exists yet (HealthKit writer and relay outbox come later): queue nothing for them,
        // so entries never sit in a permanent Pending state.
        let journalStore: SwiftDataJournalStore
        do {
            journalStore = try SwiftDataJournalStore(
                url: directory.appendingPathComponent("journal.store"),
                enabledDestinations: []
            )
        } catch {
            throw StoreStartupError.journal(error)
        }
        do {
            let favoritesStore = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
            return AppServices(journalStore: journalStore, favoritesStore: favoritesStore)
        } catch {
            journalStore.close()
            throw StoreStartupError.favorites(error)
        }
    }

    /// Which store file failed to open at startup, so the failure screen names the right one.
    enum StoreStartupError: LocalizedError {
        case journal(Error)
        case favorites(Error)

        var errorDescription: String? {
            switch self {
            case .journal(let error):
                return "The journal store file could not be opened: \(error.localizedDescription)"
            case .favorites(let error):
                return "The favorites store file could not be opened: \(error.localizedDescription)"
            }
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
