import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Diagnostic only: prints each logged-units read during the Library load, so the call order is observed.
@MainActor
final class DiagnosticUnitReadsTests: XCTestCase {
    func testDiagLibraryLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let store = UnitReadLogStore(inner: inner)
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        print("DIAG_LIBRARY_INIT_BEGIN")
        let model = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        print("DIAG_LIBRARY_LOAD_BEGIN")
        model.load()
        print("DIAG_LIBRARY_END calls=\(store.unitReadCalls) error=\(model.errorMessage ?? "nil")")
    }
}
