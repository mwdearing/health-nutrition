import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

/// Answers every component as a food value, whether or not a snapshot is passed: the lookup a food-only path would use.
private struct FoodValueFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue { .known(10, .g) }
    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue { .known(10, .g) }
}

/// An entry whose product snapshot cannot be read must not be valued as food: it is unknown for the day (#775).
@MainActor
final class DailyTotalsUnreadableSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testAnEntryWhoseSnapshotCannotBeReadIsUnknownNotFood() throws {
        let journal = try makeJournal()
        let product = ProductDefinition(
            snapshotID: "snap-unreadable", productID: "synthetic-product", name: "Synthetic supplement",
            labelBasis: "per serving (1 tablet)", catalogOrigin: "test", catalogVersion: "unknown",
            kind: .supplement, nutrients: [:])
        let intake = Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC")
        try journal.create(
            intake,
            components: [IntakeComponent(componentID: "tablet", name: "Example tablet", amount: 1, unit: .tablet)],
            product: product, now: now)
        let store = ProductReadFailingStore(base: journal, failingSnapshotID: "snap-unreadable")

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: FoodValueFacts(), nutrients: ["protein"])

        let protein = try XCTUnwrap(totals.total(for: "protein"))
        XCTAssertTrue(protein.coverage.hasUnknown, "an unreadable snapshot makes its nutrient unknown for the day")
        if case .known = protein.value {
            XCTFail("an unreadable snapshot was valued as food: \(protein.value)")
        }
    }
}
