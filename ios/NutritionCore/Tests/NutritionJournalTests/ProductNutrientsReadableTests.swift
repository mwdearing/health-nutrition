import XCTest
@testable import NutritionJournal

/// A damaged nutrient payload must not read as a product with no nutrients (#1221 item 1).
final class ProductNutrientsReadableTests: XCTestCase {
    func testAMissingPayloadIsReadable() {
        XCTAssertTrue(SwiftDataJournalStore.nutrientsReadable(nil))
    }

    func testAnEmptyListIsReadable() {
        XCTAssertTrue(SwiftDataJournalStore.nutrientsReadable("[]"))
    }

    func testAPayloadThatDoesNotDecodeIsNotReadable() {
        XCTAssertFalse(SwiftDataJournalStore.nutrientsReadable("{not json"))
        XCTAssertFalse(SwiftDataJournalStore.nutrientsReadable("{\"id\":\"fiber\"}"))
    }
}
