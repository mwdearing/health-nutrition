import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The drink water share: the presets a drink type prefills, and what a component stores when it sets none.
final class DrinkWaterShareTests: XCTestCase {
    func testEveryDrinkTypePresetIsAPercentageFromZeroToHundred() {
        for type in DrinkType.allCases {
            XCTAssertGreaterThanOrEqual(type.hydrationPercent, 0, type.rawValue)
            XCTAssertLessThanOrEqual(type.hydrationPercent, 100, type.rawValue)
        }
    }

    func testWaterPresetIsWholeAndSodaIsTheNinetyPercentDefault() {
        XCTAssertEqual(DrinkType.water.hydrationPercent, 100)
        XCTAssertEqual(DrinkType.soda.hydrationPercent, IntakeComponent.defaultDrinkHydrationPercent)
    }

    func testAComponentWithoutAShareStoresNone() throws {
        let food = IntakeComponent(componentID: "rice", name: "Rice", amount: 100, unit: try MeasureUnit(symbol: "g"))
        XCTAssertNil(food.hydrationPercent)
    }

    /// The store refuses a water share outside 0 to 100, or one that is not plain decimal text.
    func testTheStoreRefusesAShareOutsideTheRange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for share in [Decimal(101), Decimal(-1)] {
            XCTAssertThrowsError(try store.create(
                Intake(id: UUID().uuidString.lowercased(), category: "other", occurredAt: now, timeZoneIdentifier: "UTC"),
                components: [IntakeComponent(componentID: "soda", name: "Soda", amount: 200, unit: .mL, hydrationPercent: share)],
                product: nil, now: now), "a share of \(share) must be refused")
        }
    }
}
