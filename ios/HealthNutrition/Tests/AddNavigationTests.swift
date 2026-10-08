import NutritionUI
import XCTest
@testable import HealthNutrition

@MainActor
final class AddNavigationTests: XCTestCase {
    func testAddNavigationResetsOnCancelAndSave() {
        let model = AddNavigationModel()
        for route in [AddRoute.barcodeScanner, .labelScanner, .library, .details(nil)] {
            model.path = [route]
            model.reset()
            XCTAssertEqual(model.path, [])
        }
    }
}
