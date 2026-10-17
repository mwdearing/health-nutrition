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

    func testOutsideTotalsNameWhatOtherAppsLoggedInTheRightUnits() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(outsideNutrients: ["energy": 620, "protein": 48, "water": 473.1765])
        var system = UnitSystem.usCustomary
        let model = BodyActivityViewModel(reader: reader, unitSystem: { system })
        await model.load(now: now)

        XCTAssertEqual(model.outsideText, "From other apps: 620 kcal, 48 g protein, 16 fl oz water")

        system = .metric
        XCTAssertEqual(model.outsideText, "From other apps: 620 kcal, 48 g protein, 473 mL water")
    }

    func testNoOutsideTotalsMeansNoOutsideLine() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(steps: 4_000)
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        await model.load(now: now)

        XCTAssertNil(model.outsideText)
    }

    func testWeightFollowsTheUnitSystemAndShowsTheTrend() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(
            latestWeightKg: 80, latestWeightDate: now, earlierWeightKg: 81,
            earlierWeightDate: now.addingTimeInterval(-34 * 86_400))
        var system = UnitSystem.usCustomary
        let model = BodyActivityViewModel(reader: reader, unitSystem: { system })
        await model.load(now: now)

        XCTAssertEqual(model.weightText, "176.4 lb")
        XCTAssertEqual(model.weightTrendText, "Down 2.2 lb over 34 days")

        system = .metric
        XCTAssertEqual(model.weightText, "80 kg")
        XCTAssertEqual(model.weightTrendText, "Down 1 kg over 34 days")
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

    func testATinyChangeReadsAsNoChange() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(
            latestWeightKg: Decimal(string: "80.01")!, latestWeightDate: now, earlierWeightKg: 80,
            earlierWeightDate: now.addingTimeInterval(-30 * 86_400))
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        await model.load(now: now)

        XCTAssertEqual(model.weightTrendText, "No change over 30 days")
    }

    func testEveryReadIsHandedOnForTheCalorieGoal() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(activeEnergyKcal: 300)
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        var handed: [Decimal?] = []
        model.onRead = { handed.append($0.activeEnergyKcal) }

        await model.load(now: now)
        reader.hasAskedForReadAccess = false
        await model.load(now: now)

        XCTAssertEqual(handed, [300, nil], "a forgotten request hands on nothing, so the goal drops back")
    }

    func testTheActivityGoalChoiceIsOffByDefaultAndErased() {
        let preferences = InMemoryDisplayPreferences()
        XCTAssertFalse(preferences.addsActiveEnergyToGoal)
        preferences.setAddsActiveEnergyToGoal(true)
        XCTAssertTrue(preferences.addsActiveEnergyToGoal)
        preferences.resetToDefaults()
        XCTAssertFalse(preferences.addsActiveEnergyToGoal)
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
