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

    /// A drink whose product cannot be read may carry a stored hydration share: its water is unknown for the day,
    /// not dropped as if it had no water (#1433 review P2).
    func testAnUnreadableDrinkWithAHydrationShareMakesTheDaysWaterUnknown() throws {
        let journal = try makeJournal()
        let product = ProductDefinition(
            snapshotID: "snap-drink", productID: "synthetic-drink", name: "Synthetic drink",
            labelBasis: "per 100 mL", catalogOrigin: "test", catalogVersion: "unknown", kind: .drink, nutrients: [:])
        let intake = Intake(id: UUID().uuidString.lowercased(), category: "drink", occurredAt: now, timeZoneIdentifier: "UTC")
        try journal.create(
            intake,
            components: [IntakeComponent(componentID: "soda", name: "Synthetic soda", amount: 200, unit: .mL, hydrationPercent: 50)],
            product: product, now: now)
        let store = ProductReadFailingStore(base: journal, failingSnapshotID: "snap-drink")

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: FoodValueFacts(), nutrients: ["water"])

        let water = try XCTUnwrap(totals.total(for: "water"))
        XCTAssertTrue(water.coverage.hasUnknown, "a drink with a hydration share and an unreadable product makes the day's water unknown")
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
