import XCTest
@testable import NutritionCore

final class NutritionCoreTests: XCTestCase {
    func testSchemaVersion() {
        XCTAssertEqual(NutritionCore.schemaVersion, 1)
    }
}
