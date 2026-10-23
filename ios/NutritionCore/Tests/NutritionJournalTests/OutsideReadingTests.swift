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

    func testOneFailedQueryForAKeyLeavesTheKeyUnreadEvenIfAnotherSucceeded() {
        let reading = OutsideIntakeTotals.reading([
            OutsideQuery(nutrientKey: "energy", outcome: .samples([sample(energy, 620)])),
            OutsideQuery(nutrientKey: "energy", outcome: .failed),
        ])
        XCTAssertFalse(reading.readKeys.contains("energy"))
        XCTAssertTrue(reading.failed)
    }

    func testAnUnreadableUnitPlansAnUnreadKeyUnderItsOwnName() {
        let identifier = energy.quantityTypeIdentifier
        XCTAssertEqual(
            OutsideIntakeTotals.readPlan(for: identifier, unitIsReadable: { _ in false }),
            .unreadable(nutrientKey: "energy"))
    }

    func testAReadableUnitPlansTheKeyUnitAndIUFactor() {
        XCTAssertEqual(
            OutsideIntakeTotals.readPlan(for: energy.quantityTypeIdentifier, unitIsReadable: { _ in true }),
            .read(nutrientKey: "energy", unit: energy.unit, hasIUFactor: false))
        let vitaminD = HealthKitWritePlanner.mapping(for: "vitaminD")!
        XCTAssertEqual(
            OutsideIntakeTotals.readPlan(for: vitaminD.quantityTypeIdentifier, unitIsReadable: { _ in true }),
            .read(nutrientKey: "vitaminD", unit: vitaminD.unit, hasIUFactor: true))
    }

    func testAnUnnamedIdentifierPlansNothing() {
        XCTAssertEqual(
            OutsideIntakeTotals.readPlan(for: "HKQuantityTypeIdentifierNotAFood", unitIsReadable: { _ in true }),
            OutsideReadPlan.none)
    }

    func testOneUnreadableUnitQueryAndOneSuccessLeavesTheKeyUnread() {
        // Two queries for one nutrient: one has no unit to read, the other succeeds.
        let unreadable = OutsideIntakeTotals.readPlan(for: energy.quantityTypeIdentifier, unitIsReadable: { _ in false })
        guard case .unreadable(let key) = unreadable else { return XCTFail("expected an unreadable plan") }
        let reading = OutsideIntakeTotals.reading([
            OutsideQuery(nutrientKey: key, outcome: .failed),
            OutsideQuery(nutrientKey: "energy", outcome: .samples([sample(energy, 620)])),
        ])
        XCTAssertFalse(reading.readKeys.contains("energy"))
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
