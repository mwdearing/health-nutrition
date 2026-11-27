import Foundation
import SwiftData
import XCTest
import NutritionDomain
@testable import NutritionJournal

/// A store written by V10 opens under V11 with its entries and logged units intact, and the migrated store takes
/// an excluded-favorite row (#414). Synthetic values only.
final class JournalSchemaV11MigrationTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal-swiftdata.store")
    }

    func testV10StoreMigratesToV11KeepingEntriesAndLoggedUnits() throws {
        let path = try url()
        let id = "00000000-0000-4000-8000-000000000011"
        let schema = Schema(versionedSchema: JournalSchemaV10.self)
        do {
            let container = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, url: path, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(JournalSchemaV6.IntakeRecord(
                intakeID: id, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "lunch",
                note: nil, lifecycleRaw: "active", currentRevision: 1))
            context.insert(JournalSchemaV6.RevisionRecord(
                intakeID: id, number: 1, componentsJSON: "[]", productSnapshotID: nil, changeReason: "created",
                createdAt: when, occurredAt: when, timeZoneIdentifier: "UTC"))
            context.insert(JournalSchemaV10.LoggedUnitRecord(intakeID: id, componentID: "fiber-powder", unitSymbol: "tsp"))
            try context.save()
        }

        let store = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [id])
        XCTAssertEqual(try store.loggedUnits().map(\.componentID), ["fiber-powder"])

        // The V11 entity is writable after the migration, and it leaves the entries it does not name unchanged.
        let v11 = Schema(versionedSchema: JournalSchemaV11.self)
        let container = try ModelContainer(
            for: v11, configurations: ModelConfiguration(schema: v11, url: path, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.insert(JournalSchemaV11.ExcludedFavoriteRecord(favoriteID: "favorite-synthetic"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<JournalSchemaV11.ExcludedFavoriteRecord>()).count, 1)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [id])
        store.close()
    }
}
