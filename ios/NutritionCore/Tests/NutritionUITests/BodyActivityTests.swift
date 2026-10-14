import XCTest

@testable import NutritionUI

@MainActor
final class BodyActivityTests: XCTestCase {
    private final class FakeReader: BodyActivityReading {
        var hasAskedForReadAccess = false
        var readings = BodyActivityReadings.empty
        private(set) var requests = 0
        private(set) var reads = 0

        func requestReadAccess() async {
            requests += 1
            hasAskedForReadAccess = true
        }

        func read(now: Date) async -> BodyActivityReadings {
            reads += 1
            return readings
        }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNothingIsReadBeforeThePersonAsks() async {
        let reader = FakeReader()
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })

        await model.load(now: now)

        XCTAssertTrue(model.showsConnect)
        XCTAssertEqual(reader.reads, 0, "Health is not read before the request has been shown")
    }

    func testConnectingAsksOnceThenReads() async {
        let reader = FakeReader()
        reader.readings = BodyActivityReadings(steps: 8214, activeEnergyKcal: Decimal(string: "412.6")!)
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })

        await model.connect(now: now)

        XCTAssertEqual(reader.requests, 1)
        XCTAssertFalse(model.showsConnect)
        XCTAssertEqual(model.stepsText, "8,214 steps")
        XCTAssertEqual(model.activeEnergyText, "413 kcal active")
    }

    func testWeightFollowsTheUnitSystemAndShowsTheTrend() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(
            latestWeightKg: 80, latestWeightDate: now, earlierWeightKg: 81)
        var system = UnitSystem.usCustomary
        let model = BodyActivityViewModel(reader: reader, unitSystem: { system })
        await model.load(now: now)

        XCTAssertEqual(model.weightText, "176.4 lb")
        XCTAssertEqual(model.weightTrendText, "Down 2.2 lb over 30 days")

        system = .metric
        XCTAssertEqual(model.weightText, "80 kg")
        XCTAssertEqual(model.weightTrendText, "Down 1 kg over 30 days")
    }

    func testForgettingTheRequestClearsWhatWasShown() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(steps: 100)
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        await model.load(now: now)
        XCTAssertNotNil(model.stepsText)

        reader.hasAskedForReadAccess = false
        await model.load(now: now)

        XCTAssertTrue(model.showsConnect)
        XCTAssertTrue(model.readings.isEmpty)
    }

    func testNoEarlierWeightMeansNoTrend() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(latestWeightKg: 80, latestWeightDate: now)
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        await model.load(now: now)

        XCTAssertNil(model.weightTrendText)
        XCTAssertNil(model.stepsText)
    }

    func testAnEmptyReadAfterAskingExplainsBothReasons() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        await model.load(now: now)

        XCTAssertTrue(model.readings.isEmpty)
        XCTAssertTrue(BodyActivityViewModel.emptyDetail.contains("Health app"))
    }
}
