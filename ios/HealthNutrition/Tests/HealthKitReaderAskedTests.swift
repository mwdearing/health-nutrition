import Foundation
import XCTest
@testable import HealthNutrition

/// The read-access flag: builds before nutrient reading stored it under the old key only, so their card must offer
/// the request again, and forgetting the access must clear both keys.
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

    func testCurrentFlagCountsAsAsked() {
        defaults.set(true, forKey: "healthKitReader.askedForReadAccess.nutrition")
        XCTAssertTrue(HealthKitReader(defaults: defaults).hasAskedForReadAccess)
    }

    func testForgettingAccessClearsBothKeys() {
        defaults.set(true, forKey: "healthKitReader.askedForReadAccess")
        defaults.set(true, forKey: "healthKitReader.askedForReadAccess.nutrition")
        HealthKitReader.forgetReadAccess(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "healthKitReader.askedForReadAccess"))
        XCTAssertNil(defaults.object(forKey: "healthKitReader.askedForReadAccess.nutrition"))
        XCTAssertFalse(HealthKitReader(defaults: defaults).hasAskedForReadAccess)
    }
}
