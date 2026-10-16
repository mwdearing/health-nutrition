import Foundation
import SwiftData
import XCTest
import NutritionDomain
@testable import NutritionJournal

/// The schema 0.1.23 shipped (V8) opens under V9 with its entries intact, every entry in Library, and the migrated
/// store still takes a Library choice.
final class JournalSchemaV9MigrationTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal-swiftdata.store")
    }

    func testV8StoreMigratesToV9WithEveryEntryInLibraryAndAcceptsAChoice() throws {
        let path = try url()
        let id = "00000000-0000-4000-8000-000000000009"
        let schema = Schema(versionedSchema: JournalSchemaV8.self)
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
            try context.save()
        }

        let store = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try store.activeIntakes().map(\.id), [id])
        XCTAssertTrue(try store.intakeIDsNotSavedToLibrary().isEmpty)

        let other = "00000000-0000-4000-8000-00000000000a"
        try store.keepOutOfLibrary(intakeID: other)
        XCTAssertEqual(try store.intakeIDsNotSavedToLibrary(), [other])
        store.close()
    }
}
