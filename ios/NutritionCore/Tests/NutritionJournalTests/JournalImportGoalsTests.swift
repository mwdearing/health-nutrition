import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Goals in a version 8 export: restored add-only, never over a goal the device already has.
final class JournalImportGoalsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func journal() throws -> SwiftDataJournalStore {
        let store = try SwiftDataJournalStore(url: try directory().appendingPathComponent("journal.store"))
        addTeardownBlock { store.close() }
        return store
    }

    private func goalStore() throws -> SwiftDataGoalStore {
        let store = try SwiftDataGoalStore(url: try directory().appendingPathComponent("goals.store"))
        addTeardownBlock { store.close() }
        return store
    }

    /// A document with no entries and only the given goals, encoded as the app writes it.
    private func goalsExport(_ goals: [JournalExportGoal], schemaVersion: Int = JournalExport.currentSchemaVersion) throws -> Data {
        try JournalExporter.encode(
            JournalExport(
                schemaVersion: schemaVersion, exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: "test", intakes: [], tombstones: [], favorites: [], goals: goals))
    }

    private let protein = JournalExportGoal(nutrient: "protein", target: "60", unit: "g")

    func testAMissingGoalIsAddedAndCounted() throws {
        let goals = try goalStore()
        let summary = try JournalImporter.importExport(
            try goalsExport([protein]), into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(try goals.goal(for: "protein")?.target, Decimal(60))
        XCTAssertEqual(summary.goals, 1)
    }

    func testAnExistingGoalIsNeverReplaced() throws {
        let goals = try goalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(80), unit: .g))
        let summary = try JournalImporter.importExport(
            try goalsExport([protein]), into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(try goals.goal(for: "protein")?.target, Decimal(80))
        XCTAssertEqual(summary.goals, 0)
    }

    func testReimportingTheSameFileChangesNothing() throws {
        let goals = try goalStore()
        let data = try goalsExport([protein])
        _ = try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: goals)
        let again = try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(try goals.goals().map(\.nutrient), ["protein"])
        XCTAssertEqual(again.goals, 0)
    }

    func testGoalsInFileWithoutAGoalsStoreAreRefused() throws {
        XCTAssertThrowsError(
            try JournalImporter.importExport(try goalsExport([protein]), into: try journal(), favorites: nil, goals: nil)
        ) { error in
            guard case JournalImportError.corrupt = error else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    func testAVersion7FileHasNoGoalsAndStillImports() throws {
        let goals = try goalStore()
        let summary = try JournalImporter.importExport(
            try goalsExport([], schemaVersion: 7), into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(summary.goals, 0)
        XCTAssertTrue(try goals.goals().isEmpty)
    }
}
