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
}
