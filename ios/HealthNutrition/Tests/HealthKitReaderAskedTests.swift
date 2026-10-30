import Foundation
import HealthKit
import XCTest
@testable import HealthNutrition

/// The read-access flag: builds before nutrient reading, and then before height, stored it under an older key only,
/// so their card must offer the request again, and forgetting the access must clear every key.
@MainActor
final class HealthKitReaderAskedTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "HealthKitReaderAskedTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testLegacyOnlyFlagDoesNotCountAsAskedForNutrientReading() {
        defaults.set(true, forKey: "healthKitReader.askedForReadAccess")
        XCTAssertFalse(HealthKitReader(defaults: defaults).hasAskedForReadAccess)
    }

    /// A person asked before height was read is asked once more, so the permission sheet can offer height.
    func testNutritionOnlyFlagDoesNotCountAsAskedForHeight() {
        defaults.set(true, forKey: "healthKitReader.askedForReadAccess.nutrition")
        XCTAssertFalse(HealthKitReader(defaults: defaults).hasAskedForReadAccess)
    }

    func testCurrentFlagCountsAsAsked() {
        defaults.set(true, forKey: "healthKitReader.askedForReadAccess.height")
        XCTAssertTrue(HealthKitReader(defaults: defaults).hasAskedForReadAccess)
    }

    func testForgettingAccessClearsEveryKey() {
        let keys = [
            "healthKitReader.askedForReadAccess", "healthKitReader.askedForReadAccess.nutrition",
            "healthKitReader.askedForReadAccess.height",
        ]
        for key in keys { defaults.set(true, forKey: key) }
        HealthKitReader.forgetReadAccess(defaults: defaults)
        for key in keys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(HealthKitReader(defaults: defaults).hasAskedForReadAccess)
    }

    /// The decided read set (#508): height is read to prefill goal setup; alcohol is not read.
    func testTheReadSetAddsHeightAndNotAlcohol() {
        let types = HealthKitReader.readTypes
        XCTAssertTrue(types.contains(HKQuantityType(.height)))
        XCTAssertTrue(types.contains(HKQuantityType(.bodyMass)))
        XCTAssertTrue(types.contains(HKQuantityType(.stepCount)))
        XCTAssertTrue(types.contains(HKQuantityType(.activeEnergyBurned)))
        XCTAssertFalse(types.contains(HKQuantityType(.numberOfAlcoholicBeverages)))
    }
}
