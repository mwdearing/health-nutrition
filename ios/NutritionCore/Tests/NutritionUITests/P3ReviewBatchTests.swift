import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

private let noon = Date(timeIntervalSince1970: 1_700_000_000)

private struct SnapshotFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue { .unknown }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// Minor findings from the pre-release review: an entry the journal cannot fully read is never dropped from a day.
@MainActor
final class P3ReviewBatchTests: XCTestCase {
    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func oats() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-oats", productID: "product-oats", name: "Rolled oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g)])
    }

    private func log(_ store: SwiftDataJournalStore, id: String) throws -> Intake {
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: noon, timeZoneIdentifier: "UTC")
        try store.create(
            intake, components: [IntakeComponent(componentID: id, name: "Rolled oats", amount: 100, unit: .g)],
            product: oats(), now: noon)
        return try XCTUnwrap(try store.activeIntakes().first { $0.id == intake.id })
    }

    func testAnIntakeWithoutItsCurrentRevisionCountsAsUnknown() throws {
        let store = try makeStore()
        let readable = try log(store, id: "oats-a")
        var broken = try log(store, id: "oats-b")
        broken.currentRevision = 99
        let totals = try DailyTotalsBuilder.totals(
            for: [readable, broken], store: store, lookup: SnapshotFacts(), nutrients: ["protein", "iron"])
        let protein = try XCTUnwrap(totals.total(for: "protein"))
        XCTAssertTrue(protein.coverage.hasUnknown, "the entry with no current revision is unknown, not skipped")
        XCTAssertEqual(protein.coverage.totalCount, 2)
        XCTAssertEqual(protein.coverage.knownCount, 1)
        let iron = try XCTUnwrap(totals.total(for: "iron"))
        XCTAssertTrue(iron.coverage.hasUnknown, "it is unknown for every nutrient asked for")
    }

    func testNutrientGapsCountsAMissingRevisionAsUnknown() throws {
        let store = try makeStore()
        let readable = try log(store, id: "oats-a")
        var broken = try log(store, id: "oats-b")
        broken.currentRevision = 99
        let read = try NutrientGapsViewModel.tallies(
            intakes: [readable, broken], store: store, lookup: SnapshotFacts(), now: noon, zoneID: "UTC")
        let protein = try XCTUnwrap(read.tallies["protein"])
        XCTAssertEqual(protein.known, 1)
        XCTAssertEqual(protein.missing, 1, "the entry with no current revision is one unknown entry")
        let iron = try XCTUnwrap(read.tallies["iron"])
        XCTAssertEqual(iron.missing, 2, "unknown for every nutrient, not skipped")
        XCTAssertEqual(read.loggedDays, 1)
    }

    func testAnUnreadableSnapshotIsNotCountedAsFoodOnToday() throws {
        let store = try makeStore()
        let supplement = ProductDefinition(
            snapshotID: "snapshot-multi", productID: "product-multi", name: "Synthetic multi", labelBasis: "per serving",
            catalogOrigin: "test", catalogVersion: "1", kind: .supplement, nutrients: ["zinc": .known(Decimal(10), .mg)])
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: noon, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "multi", name: "Synthetic multi", amount: 1, unit: .serving)],
            product: supplement, now: noon)
        try store.damageNutrientsOnSnapshotForTesting(snapshotID: "snapshot-multi")
        let model = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        model.load(now: noon)
        let row = try XCTUnwrap(model.rows.first { $0.id == id })
        XCTAssertEqual(row.kind, .supplement, "a damaged product keeps its kind instead of becoming food")
    }

    func testAFailedProductReadDoesNotDuplicateALibraryRow() throws {
        let store = try makeStore()
        let custom = CustomProductRevision(
            localProductID: UUID(), revisionID: UUID(), content: .init(name: "Synthetic tea", kind: .drink, basis: .perServing))
        try store.saveCustomProduct(.init(revision: custom), now: noon)
        let product = ProductDefinition(
            snapshotID: "snapshot-tea", productID: custom.localProductID.uuidString, name: "Synthetic tea",
            labelBasis: "per serving", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["zinc": .known(Decimal(1), .mg)])
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: noon, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "tea", name: "Synthetic tea", amount: 1, unit: .serving)],
            product: product, now: noon)
        try store.damageNutrientsOnSnapshotForTesting(snapshotID: "snapshot-tea")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let model = LibraryViewModel(store: store, favorites: favorites, productStore: store, timeZoneIdentifier: "UTC")
        model.load()
        let ids = model.sections.flatMap(\.items).map(\.id) + model.loggedProducts.map(\.id)
        XCTAssertFalse(ids.contains { $0.hasPrefix("food:") }, "the product is listed once, as its saved product")
    }
}
