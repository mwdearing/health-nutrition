import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// "Erase all data" on the Connections and privacy screen. Every store it names has to come back empty
/// and usable afterwards, so an erase is a new start rather than a broken store.
final class JournalEraseTests: XCTestCase {
    private let intakeID = "3f5a1c72-8d64-4b19-9e0a-2c7f6b4d8e51"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func sampleIntake() -> Intake {
        Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast")
    }

    private func oats() -> IntakeComponent {
        IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 40, unit: .g)
    }

    private func product() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snap-erase-1", productID: "product-1", name: "Sample oats", brand: "Sample Brand",
            barcode: "00000000", labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1")
    }

    private func sampleFavorite(_ id: String) -> FavoriteTemplate {
        FavoriteTemplate(
            id: id, displayName: "Oat porridge", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "40", unitSymbol: "g")])
    }

    /// Every table the journal owns goes, and the file it lives in stays: the store stays open and a
    /// create() afterwards has to succeed.
    func testEraseRemovesEveryJournalRecordAndTheStoreStaysUsable() throws {
        let directory = try makeDirectory()
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        try store.create(sampleIntake(), components: [oats()], product: product(), now: when)
        try store.edit(
            intakeID: intakeID, components: [oats()], product: nil, changeReason: "bigger bowl", now: when)
        try store.delete(intakeID: intakeID, now: when)
        XCTAssertFalse(try store.activeIntakes().isEmpty)
        XCTAssertFalse(try store.deletedIntakes().isEmpty)
        XCTAssertFalse(try store.pendingOutbox().isEmpty)

        try store.eraseAll()

        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.deletedIntakes().isEmpty)
        XCTAssertTrue(try store.revisions(of: intakeID).isEmpty)
        XCTAssertTrue(try store.projections(of: intakeID).isEmpty)
        XCTAssertTrue(try store.pendingOutbox().isEmpty)
        XCTAssertNil(try store.product(snapshotID: "snap-erase-1"))
        let snapshot = try store.readJournalSnapshot()
        XCTAssertTrue(snapshot.activeIntakes.isEmpty)
        XCTAssertTrue(snapshot.deletedIntakes.isEmpty)

        // The container was not closed: a new entry can be written into the same store.
        try store.create(sampleIntake(), components: [oats()], product: nil, now: when)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [intakeID])
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
    }

    func testEraseRemovesEveryFavorite() throws {
        let store = try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))
        try store.add(sampleFavorite("fav-1"))
        try store.add(sampleFavorite("fav-2"))
        XCTAssertEqual(try store.list().count, 2)

        try store.eraseAll()

        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertFalse(try store.contains(id: "fav-1"))
        // Still open: another favorite can be added afterwards.
        try store.add(sampleFavorite("fav-3"))
        XCTAssertEqual(try store.list().map(\.id), ["fav-3"])
    }

    /// Recipes keep every version and the tombstones of the deleted ones. Both are personal data, so
    /// both go.
    func testEraseRemovesEveryRecipeVersionAndTombstone() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        try store.saveNewVersion(sampleVersion())
        try store.saveNewVersion(sampleVersion(number: 2, title: "Oat bake, richer"))
        try store.deleteRecipe(id: "recipe-1")
        XCTAssertEqual(try store.versions(of: "recipe-1").count, 2)
        XCTAssertTrue(try store.list().recipes.isEmpty)

        try store.eraseAll()

        XCTAssertTrue(try store.versions(of: "recipe-1").isEmpty)
        XCTAssertNil(try store.version(recipeID: "recipe-1", number: 1))
        XCTAssertTrue(try store.list().recipes.isEmpty)
        // The tombstone went too, so the recipe id can be used again from version one.
        try store.saveNewVersion(sampleVersion())
        XCTAssertEqual(try store.list().recipes.map(\.recipeID), ["recipe-1"])
    }

    /// A closed store has nothing left to erase and says so with its own error, rather than silently
    /// reporting success.
    func testEraseOnAClosedStoreThrowsItsOwnClosedError() throws {
        let directory = try makeDirectory()
        let journal = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let recipes = try SwiftDataRecipeStore(url: directory.appendingPathComponent("recipes.store"))
        journal.close()
        favorites.close()
        recipes.close()

        XCTAssertThrowsError(try journal.eraseAll()) { XCTAssertEqual($0 as? JournalError, .closed) }
        XCTAssertThrowsError(try favorites.eraseAll()) { XCTAssertEqual($0 as? FavoritesError, .closed) }
        XCTAssertThrowsError(try recipes.eraseAll()) { XCTAssertEqual($0 as? RecipeStoreError, .closed) }
    }

    /// A store that is open and already empty erases without complaint: the action is offered whatever
    /// the journal holds, so it has to be harmless.
    func testEraseOnAnEmptyStoreSucceeds() throws {
        let directory = try makeDirectory()
        let journal = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let recipes = try SwiftDataRecipeStore(url: directory.appendingPathComponent("recipes.store"))
        XCTAssertNoThrow(try journal.eraseAll())
        XCTAssertNoThrow(try favorites.eraseAll())
        XCTAssertNoThrow(try recipes.eraseAll())
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try favorites.list().isEmpty)
        XCTAssertTrue(try recipes.list().recipes.isEmpty)
    }

    /// A save that fails must leave the journal as it was, so a failed erase never loses half the data
    /// and reports success.
    func testAFailedEraseRollsBackAndLeavesTheJournalIntact() throws {
        let directory = try makeDirectory()
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        try store.create(sampleIntake(), components: [oats()], product: product(), now: when)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual($0 as? JournalError, .injectedSaveFailure)
        }
        XCTAssertEqual(try store.activeIntakes().map(\.id), [intakeID])
        XCTAssertEqual(try store.revisions(of: intakeID).count, 1)
        XCTAssertFalse(try store.pendingOutbox().isEmpty)
    }

    /// The screen runs whichever stores it was given, so each store can be erased on its own and every
    /// one of them is reachable through the protocol the screen holds.
    func testEveryStoreConformsToTheEraseProtocol() throws {
        let directory = try makeDirectory()
        let erasers: [JournalErasing] = [
            try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store")),
            try SwiftDataRecipeStore(url: directory.appendingPathComponent("recipes.store")),
        ]
        XCTAssertEqual(erasers.count, 3)
        for eraser in erasers {
            XCTAssertNoThrow(try eraser.eraseAll())
        }
    }
}