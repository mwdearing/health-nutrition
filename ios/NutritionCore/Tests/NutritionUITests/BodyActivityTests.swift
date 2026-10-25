import NutritionDomain
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
        XCTAssertEqual(model.activeEnergyText, "413 Calories active")
    }

    func testOutsideTotalsNameWhatOtherAppsLoggedInTheRightUnits() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(
            outsideNutrients: ["energy": 620, "protein": 48, "water": 473.1765], outsideRead: true,
            outsideReadKeys: ["energy", "protein", "water"])
        var system = UnitSystem.usCustomary
        let model = BodyActivityViewModel(reader: reader, unitSystem: { system })
        await model.load(now: now)

        XCTAssertEqual(model.outsideText, "From other apps: 620 Calories, 48 g protein, 16 fl oz water")

        system = .metric
        XCTAssertEqual(model.outsideText, "From other apps: 620 Calories, 48 g protein, 473 mL water")
    }

    func testAFailedOutsideReadSaysSoRatherThanShowingNothing() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(steps: 4_000, outsideReadFailed: true)
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        await model.load(now: now)

        XCTAssertEqual(model.outsideText, "From other apps: could not be read")
    }

    func testNoOutsideTotalsMeansNoOutsideLine() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(steps: 4_000)
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric })
        await model.load(now: now)

        XCTAssertNil(model.outsideText)
    }

    func testWeightFollowsTheUnitSystem() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        reader.readings = BodyActivityReadings(latestWeightKg: 80, latestWeightDate: now)
        var system = UnitSystem.usCustomary
        let model = BodyActivityViewModel(reader: reader, unitSystem: { system })
        await model.load(now: now)

        XCTAssertEqual(model.weightText, "176.4 lb")

        system = .metric
        XCTAssertEqual(model.weightText, "80 kg")
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

    func testALatestWeightAloneGivesNoTrend() async {
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

    func testTheWeightLinesUseGregorianDaysOnADeviceSetToAnotherCalendar() async {
        let reader = FakeReader()
        reader.hasAskedForReadAccess = true
        let today = Date(timeIntervalSince1970: 1_776_254_400)
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: today)
        readings.weightSamples = [
            WeightSample(day: CalendarDay(iso: "2026-04-01")!, kilograms: 90),
            WeightSample(day: CalendarDay(iso: "2026-04-15")!, kilograms: 89),
        ]
        reader.readings = readings
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        let plan = WeightPlan(aim: .lose, goalKilograms: 80, weeklyPaceKilograms: Decimal(string: "0.25")!)
        let model = BodyActivityViewModel(
            reader: reader, unitSystem: { .metric }, weightPlan: { plan }, calendar: buddhist)
        await model.load(now: today)

        // The Buddhist year of April 15, 2026 is 2569; the days still count from April 15, 2026.
        XCTAssertEqual(model.weightTrendText, "Trend: down 0.5 kg a week")
        XCTAssertEqual(model.planGoalDayText, "Plan reaches 80 kg on Dec 23, 2026")
        XCTAssertEqual(model.trendGoalDayText, "Trend reaches 80 kg on Aug 19, 2026")
    }
}
