import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The reference table and the nutrient mapping must agree, or a reference value would be compared
/// against a total counted in a different unit, or would name a key the journal never sums.
final class ReferenceIntakesMappingTests: XCTestCase {
    func testEveryReferenceKeyIsAMicronutrientCountedInTheSameUnit() throws {
        let group = ReferenceGroup(sex: .female, ageBand: .years31To50)
        for intake in ReferenceIntakes.intakes(for: group) {
            XCTAssertTrue(
                HealthKitWritePlanner.micronutrientKeys.contains(intake.nutrient),
                "\(intake.nutrient) is not a tracked vitamin or mineral")
            let mapping = try XCTUnwrap(HealthKitWritePlanner.mapping(for: intake.nutrient), intake.nutrient)
            XCTAssertEqual(mapping.nutrientKey, intake.nutrient, "the table must use the canonical key")
            XCTAssertEqual(mapping.unit, intake.unit, "\(intake.nutrient) is counted in \(mapping.unit.symbol)")
        }
    }

    func testOnlyChlorideIsLeftOutOfTheTable() {
        let uncovered = HealthKitWritePlanner.micronutrientKeys.filter {
            !ReferenceIntakes.nutrients.contains($0)
        }
        XCTAssertEqual(uncovered, ["chloride"])
    }
}
