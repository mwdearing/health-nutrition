import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// "Complete product" is offered only when the item's product can be read: a failed read is not taken as "not a
/// quick add" (#775), so the action is not offered on a guess.
@MainActor
final class LibraryCompleteProductReadTests: XCTestCase {
    private func makeStore() throws -> UnitReadCountingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UnitReadCountingStore(inner: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")))
    }

    private func makeLibrary(_ store: JournalStore) throws -> LibraryViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        return LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
    }

    private func item(snapshotID: String) -> LibraryItem {
        let template = RepeatTemplate(
            displayName: "Synthetic oats", category: "food",
            components: [.init(componentID: "oats", name: "Oats", amount: 40, unit: .g)], productSnapshotID: snapshotID)
        return LibraryItem(id: "synthetic", title: template.displayName, detail: "40 g", isFavorite: false, template: template)
    }

    func testAProductThatCannotBeReadIsNotOfferedForCompletion() throws {
        let store = try makeStore()
        store.failsProductReads = true
        let library = try makeLibrary(store)
        XCTAssertFalse(library.canCompleteProduct(item(snapshotID: "s-unreadable")))
    }

    func testAReadableProductIsStillOffered() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let product = ProductDefinition(
            snapshotID: "s-oats", productID: "p-oats", name: "Synthetic oats", labelBasis: "per 100 g",
            catalogOrigin: "test", catalogVersion: "1", kind: .food, nutrients: [:])
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC", meal: nil),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)], product: product, now: now)
        let library = try makeLibrary(store)
        XCTAssertTrue(library.canCompleteProduct(item(snapshotID: "s-oats")))
    }
}
