import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A drink repeated from a template saved before shares stores the default share on the new entry, counts
/// it toward Today's water, and puts the same share in the Health write. Both a favorite and a saved meal
/// item repeat through the same template path.
@MainActor
final class DrinkRepeatShareTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// Stores a drink product, then repeats a pre-share template of it and returns the new entry's id.
    private func repeatLegacy(_ template: FavoriteTemplate, in store: SwiftDataJournalStore) throws -> String {
        let drink = ProductDefinition(
            snapshotID: "snap-repeat-drink", productID: "product-repeat-drink", name: "Old soda",
            labelBasis: "per serving", catalogOrigin: "manual", catalogVersion: "1", kind: .drink)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "other", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "soda", name: "Old soda", amount: 200, unit: .mL)],
            product: drink, now: now)
        let repeatTemplate = try XCTUnwrap(RepeatTemplate(favorite: template))
        return try IntakeRepeater(
            store: store, timeZoneProvider: { "UTC" }, makeID: { UUID().uuidString.lowercased() }
        ).create(from: repeatTemplate, now: now)
    }

    private func assertRepeatCounts(_ template: FavoriteTemplate, file: StaticString = #filePath, line: UInt = #line) async throws {
        let store = try makeStore()
        let copyID = try repeatLegacy(template, in: store)

        let revision = try XCTUnwrap(try store.revisions(of: copyID).first, file: file, line: line)
        let share = try XCTUnwrap(revision.components.first?.hydrationPercent, file: file, line: line)
        XCTAssertEqual(share, IntakeComponent.defaultDrinkHydrationPercent, file: file, line: line)

        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        XCTAssertEqual(today.waterTotalMilliliters, 180, "200 mL at 90 percent is 180 mL", file: file, line: line)

        let health = try await JournalSnapshotTotals(store: store).totals(intakeID: copyID, revision: revision.number)
        XCTAssertEqual(health["water"], .known(180, .mL), "the Health write carries the same share", file: file, line: line)
    }

    func testRepeatingAPreShareFavoriteCountsTheDefaultShare() async throws {
        try await assertRepeatCounts(FavoriteTemplate(
            id: "fav-legacy-repeat", displayName: "Old soda", category: "drink",
            components: [FavoriteComponent(componentID: "soda", name: "Old soda", amountText: "200", unitSymbol: "mL")],
            productSnapshotID: "snap-repeat-drink"))
    }

    func testRepeatingAPreShareSavedMealItemCountsTheDefaultShare() async throws {
        try await assertRepeatCounts(FavoriteTemplate(
            id: "meal-item-legacy-repeat", displayName: "Old soda", category: "drink",
            components: [FavoriteComponent(componentID: "soda", name: "Old soda", amountText: "200", unitSymbol: "mL")],
            productSnapshotID: "snap-repeat-drink"))
    }
}
