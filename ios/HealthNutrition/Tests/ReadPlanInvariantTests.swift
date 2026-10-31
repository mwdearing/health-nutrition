import NutritionJournal
import XCTest

@testable import HealthNutrition

/// The reader plans a read only for a unit HealthKit has a unit for. Pinned for every mapping, so the two predicates cannot drift.
@MainActor
final class ReadPlanInvariantTests: XCTestCase {
    func testEveryMappingIsReadableExactlyWhenHealthKitHasItsUnit() {
        for mapping in HealthKitWritePlanner.mappings {
            let hasHealthKitUnit = HealthKitReader.healthKitUnit(for: mapping.unit) != nil
            let plan = OutsideIntakeTotals.readPlan(for: mapping.quantityTypeIdentifier, unitIsReadable: {
                HealthKitReader.healthKitUnit(for: $0) != nil
            })
            if hasHealthKitUnit {
                guard case .read(let key, _, _) = plan else {
                    XCTFail("\(mapping.nutrientKey) has a HealthKit unit but is not planned as read")
                    continue
                }
                XCTAssertEqual(key, mapping.nutrientKey)
            } else {
                guard case .unreadable(let key) = plan else {
                    XCTFail("\(mapping.nutrientKey) has no HealthKit unit but is planned as read")
                    continue
                }
                XCTAssertEqual(key, mapping.nutrientKey)
            }
        }
    }

    /// The units the write-plan mappings use, pinned by hand. If a mapping adds a unit, this list must change with it,
    /// and that unit must have a HealthKit unit, so no mapped nutrient can drop out of the read plan without a failure.
    func testEveryMappedUnitIsPinnedAndHasAHealthKitUnit() {
        let pinned: Set<String> = ["g", "mg", "mcg", "mL", "kcal"]
        let used = Set(HealthKitWritePlanner.mappings.map(\.unit.symbol))
        XCTAssertEqual(used, pinned, "a mapped unit changed; pin it here and give it a HealthKit unit")
        for mapping in HealthKitWritePlanner.mappings {
            XCTAssertNotNil(HealthKitReader.healthKitUnit(for: mapping.unit), "\(mapping.nutrientKey) has no HealthKit unit")
        }
    }
}
