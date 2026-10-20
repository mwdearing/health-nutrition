import Foundation
import NutritionDomain
import XCTest

@testable import NutritionJournal

/// The rules for one day's outside reading, tested without HealthKit: a failed query, an unconvertible sample,
/// and the app's own samples each leave the right nutrient read or unread.
final class OutsideReadingTests: XCTestCase {
    private let energy = HealthKitWritePlanner.mapping(for: "energy")!
    private let protein = HealthKitWritePlanner.mapping(for: "protein")!

    private func sample(_ mapping: HealthKitNutrientMapping, _ value: Decimal, own: Bool = false) -> OutsideSampleOutcome {
        .sample(OutsideNutrientSample(
            quantityTypeIdentifier: mapping.quantityTypeIdentifier, value: value, unit: mapping.unit,
            isWrittenByThisApp: own))
    }

    func testAllQueriesReadCompletely() {
        let reading = OutsideIntakeTotals.reading([
            OutsideQuery(nutrientKey: "energy", outcome: .samples([sample(energy, 620)])),
            OutsideQuery(nutrientKey: "protein", outcome: .samples([])),
        ])
        XCTAssertEqual(reading.totals, ["energy": 620])
        XCTAssertEqual(reading.readKeys, ["energy", "protein"])
        XCTAssertFalse(reading.failed)
    }

    func testUnconvertibleSampleLeavesItsNutrientUnreadAndKeepsTheSum() {
        let reading = OutsideIntakeTotals.reading([
            OutsideQuery(nutrientKey: "protein", outcome: .samples([sample(protein, 10), .unconvertible])),
            OutsideQuery(nutrientKey: "energy", outcome: .samples([sample(energy, 620)])),
        ])
        XCTAssertEqual(reading.totals["protein"], 10)
        XCTAssertFalse(reading.readKeys.contains("protein"))
        XCTAssertTrue(reading.readKeys.contains("energy"))
        XCTAssertTrue(reading.failed)
    }

    func testFailedQueryLeavesItsNutrientUnreadAndTheOthersReport() {
        let reading = OutsideIntakeTotals.reading([
            OutsideQuery(nutrientKey: "protein", outcome: .failed),
            OutsideQuery(nutrientKey: "energy", outcome: .samples([sample(energy, 620)])),
        ])
        XCTAssertNil(reading.totals["protein"])
        XCTAssertEqual(reading.readKeys, ["energy"])
        XCTAssertEqual(reading.totals["energy"], 620)
        XCTAssertTrue(reading.failed)
    }

    func testUnmappedQueryFailsTheReadingWithoutAKey() {
        let reading = OutsideIntakeTotals.reading([OutsideQuery(nutrientKey: "", outcome: .unmapped)])
        XCTAssertTrue(reading.readKeys.isEmpty)
        XCTAssertTrue(reading.failed)
    }

    func testTheAppsOwnSampleIsLeftOutButItsQueryStillCountsAsRead() {
        let reading = OutsideIntakeTotals.reading([
            OutsideQuery(nutrientKey: "energy", outcome: .samples([sample(energy, 500, own: true)])),
        ])
        XCTAssertNil(reading.totals["energy"])
        XCTAssertEqual(reading.readKeys, ["energy"])
        XCTAssertFalse(reading.failed)
    }
}
