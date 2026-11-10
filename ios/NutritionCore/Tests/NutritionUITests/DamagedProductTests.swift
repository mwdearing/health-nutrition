import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

private struct SnapshotOnlyFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue { .unknown }
    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// An entry whose product has a damaged nutrient payload must never be stuck. Synthetic values only.
@MainActor
final class DamagedProductTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func damagedStore() throws -> (SwiftDataJournalStore, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let id = UUID().uuidString.lowercased()
        let product = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Oats", labelBasis: "per 100 g",
            catalogOrigin: "test", catalogVersion: "1", nutrients: ["protein": .known(Decimal(13), .g)])
        try store.create(
            Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: product, now: now)
        try store.damageNutrientsOnSnapshotForTesting(snapshotID: "snap-1")
        return (store, id)
    }

    func testAnEntryWithADamagedProductCanStillBeDeleted() throws {
        let (store, id) = try damagedStore()
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.productUnreadableNote, "This product's details could not be read.")
        XCTAssertTrue(model.delete(now: now))
        XCTAssertTrue(try store.activeIntakes().isEmpty)
    }

    func testADamagedProductCountsAsUnknownInTheDayTotal() throws {
        let (store, _) = try damagedStore()
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])
        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
    }

    /// A product that states no nutrients is stored with none; the day total reads that as
    /// unknown (partial), never as zero.
    func testAProductWithNoNutrientsCountsAsUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let bare = ProductDefinition(
            snapshotID: "snap-2", productID: "product-2", name: "Oats", labelBasis: "per 100 g",
            catalogOrigin: "test", catalogVersion: "1")
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: bare, now: now)
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])
        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
    }
}
