import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

/// A day's vitamin D adds up whether a label stated it in IU or in mcg: an IU of vitamin D is defined as
/// 0.025 mcg. Vitamins A and E have no such single factor and stay unknown when stated in IU.
@MainActor
final class VitaminDInternationalUnitTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_049_600)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func log(_ store: JournalStore, _ id: String, kind: ProductKind, nutrients: [String: NutrientValue]) throws {
        let product = ProductDefinition(
            snapshotID: "snapshot-\(id)", productID: "product-\(id)", name: id, labelBasis: "per 100 g",
            catalogOrigin: "test", catalogVersion: "1", kind: kind, nutrients: nutrients)
        let intake = Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: when, timeZoneIdentifier: "UTC")
        try store.create(
            intake, components: [IntakeComponent(componentID: id, name: id, amount: 100, unit: .g)],
            product: product, now: when)
    }

    func testVitaminDInIUAndInMcgAddUpInMcg() throws {
        let store = try makeStore()
        // 1,000 IU is 25 mcg; with the 5 mcg a food states, the day holds 30 mcg.
        try log(store, "drops", kind: .supplement, nutrients: ["vitaminD": .known(1000, .iu)])
        try log(store, "milk", kind: .food, nutrients: ["vitaminD": .known(5, .mcg)])

        let totals = try DailyTotalsBuilder.totals(
            for: store.activeIntakes(), store: store, lookup: SnapshotNutrientFacts(), nutrients: ["vitaminD"])

        XCTAssertEqual(totals.total(for: "vitaminD")?.value, .known(30, .mcg))
    }

    func testVitaminDInIUUnderTheLabelAliasIsCounted() throws {
        let store = try makeStore()
        try log(store, "drops", kind: .supplement, nutrients: ["vitamin-d": .known(400, .iu)])

        let totals = try DailyTotalsBuilder.totals(
            for: store.activeIntakes(), store: store, lookup: SnapshotNutrientFacts(), nutrients: ["vitaminD"])

        XCTAssertEqual(totals.total(for: "vitaminD")?.value, .known(10, .mcg))
    }

    func testVitaminAInIUStaysUnknown() throws {
        let store = try makeStore()
        try log(store, "multi", kind: .supplement, nutrients: ["vitaminA": .known(900, .iu)])

        let totals = try DailyTotalsBuilder.totals(
            for: store.activeIntakes(), store: store, lookup: SnapshotNutrientFacts(), nutrients: ["vitaminA"])

        XCTAssertEqual(totals.total(for: "vitaminA")?.value, .unknown)
    }
}
