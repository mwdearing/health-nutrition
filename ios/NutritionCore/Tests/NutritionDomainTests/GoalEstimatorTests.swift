import XCTest
@testable import NutritionDomain

/// The goal estimator's numbers, each worked out by hand in its test so a change to the formula shows
/// up as a failed sum rather than as a silently moved target.
///
/// Mifflin-St Jeor resting energy is `10 * kg + 6.25 * cm - 5 * age + s`, with `s` = +5 for a man,
/// -161 for a woman and -78 when the sex is not given.
final class GoalEstimatorTests: XCTestCase {
    private func profile(
        sex: GoalSex = .male, age: Int = 30, cm: Decimal = 180, kg: Decimal = 80,
        activity: ActivityLevel = .moderate, aim: GoalAim = .maintain, weekly: Decimal = 0
    ) -> GoalProfile {
        GoalProfile(
            sex: sex, ageYears: age, heightCentimeters: cm, weightKilograms: kg,
            activity: activity, aim: aim, weeklyChangeKilograms: weekly)
    }

    private func estimate(_ profile: GoalProfile) throws -> GoalEstimate {
        try XCTUnwrap(GoalEstimator.estimate(profile))
    }

    func testRestingEnergyForAManMatchesTheFormula() {
        // 10 * 80 + 6.25 * 180 - 5 * 30 + 5 = 800 + 1125 - 150 + 5 = 1780
        XCTAssertEqual(GoalEstimator.restingEnergy(profile()), 1780)
    }

    func testRestingEnergyForAWomanUsesTheLowerConstant() {
        // 800 + 1125 - 150 - 161 = 1614
        XCTAssertEqual(GoalEstimator.restingEnergy(profile(sex: .female)), 1614)
    }

    func testRestingEnergyWithoutASexUsesTheMidpointConstant() {
        // 800 + 1125 - 150 - 78 = 1697
        XCTAssertEqual(GoalEstimator.restingEnergy(profile(sex: .unspecified)), 1697)
    }

    func testActivityLevelsMultiplyRestingEnergy() {
        // Resting 1780 times each multiplier, before any rounding.
        // 1780 * 1.2 = 2136; 1780 * 1.375 = 2447.5; 1780 * 1.55 = 2759; 1780 * 1.725 = 3070.5
        XCTAssertEqual(GoalEstimator.dailyEnergy(profile(activity: .sedentary)), 2136)
        XCTAssertEqual(GoalEstimator.dailyEnergy(profile(activity: .light)), Decimal(string: "2447.5"))
        XCTAssertEqual(GoalEstimator.dailyEnergy(profile(activity: .moderate)), 2759)
        XCTAssertEqual(GoalEstimator.dailyEnergy(profile(activity: .veryActive)), Decimal(string: "3070.5"))
    }

    func testMaintainingRoundsEnergyToTheNearestTen() throws {
        // 2759 / 10 = 275.9, which rounds to 276, so 2760 kcal.
        let target = try estimate(profile(aim: .maintain))
        XCTAssertEqual(target.energyKcal, 2760)
        XCTAssertNil(target.adjustmentNote)
    }

    func testLightActivityRoundsHalfUpToTheNearestTen() throws {
        // 2447.5 / 10 = 244.75, which rounds to 245, so 2450 kcal.
        let target = try estimate(profile(activity: .light))
        XCTAssertEqual(target.energyKcal, 2450)
    }

    func testLosingHalfAKilogramAWeekSubtracts550() throws {
        // 0.5 * 7700 / 7 = 550 kcal a day. 2759 - 550 = 2209, which rounds to 2210.
        let target = try estimate(profile(aim: .lose, weekly: Decimal(string: "0.5")!))
        XCTAssertEqual(target.energyKcal, 2210)
        XCTAssertNil(target.adjustmentNote)
    }

    func testGainingHalfAKilogramAWeekAdds550() throws {
        // 2759 + 550 = 3309, which rounds to 3310.
        let target = try estimate(profile(aim: .gain, weekly: Decimal(string: "0.5")!))
        XCTAssertEqual(target.energyKcal, 3310)
        XCTAssertNil(target.adjustmentNote)
    }

    func testLossFloorForAManIs1500() throws {
        // Man, 70, 165 cm, 55 kg, sedentary.
        // Resting: 550 + 1031.25 - 350 + 5 = 1236.25. Daily: 1236.25 * 1.2 = 1483.5.
        // Lose 0.5 kg a week: 1483.5 - 550 = 933.5, below the 1500 floor, so 1500 kcal.
        let target = try estimate(profile(
            age: 70, cm: 165, kg: 55, activity: .sedentary, aim: .lose, weekly: Decimal(string: "0.5")!))
        XCTAssertEqual(target.energyKcal, 1500)
        XCTAssertEqual(target.adjustmentNote, "We raised your daily calories to the minimum we suggest.")
    }

    func testLossFloorForAWomanIs1200() throws {
        // Woman, 70, 150 cm, 45 kg, sedentary.
        // Resting: 450 + 937.5 - 350 - 161 = 876.5. Daily: 876.5 * 1.2 = 1051.8.
        // Lose 0.5 kg a week: 1051.8 - 550 = 501.8, below the 1200 floor, so 1200 kcal.
        let target = try estimate(profile(
            sex: .female, age: 70, cm: 150, kg: 45, activity: .sedentary, aim: .lose,
            weekly: Decimal(string: "0.5")!))
        XCTAssertEqual(target.energyKcal, 1200)
        XCTAssertEqual(target.adjustmentNote, "We raised your daily calories to the minimum we suggest.")
    }

    func testLossOfAKilogramAWeekIsCappedAt1000() throws {
        // 1.0 * 7700 / 7 = 1100, capped to 1000. 2759 - 1000 = 1759, which rounds to 1760.
        let target = try estimate(profile(aim: .lose, weekly: 1))
        XCTAssertEqual(target.energyKcal, 1760)
        XCTAssertEqual(target.adjustmentNote, "We limited the daily change to 1,000 calories.")
    }

    func testGainOfAKilogramAWeekIsCappedAt1000() throws {
        // 1100 capped to 1000. 2759 + 1000 = 3759, which rounds to 3760.
        let target = try estimate(profile(aim: .gain, weekly: 1))
        XCTAssertEqual(target.energyKcal, 3760)
        XCTAssertEqual(target.adjustmentNote, "We limited the daily change to 1,000 calories.")
    }

    func testMacroGramsAndFiberFromAMaintenanceTarget() throws {
        // Energy 2760 kcal.
        // Carbohydrate: 2760 * 0.50 = 1380 kcal, / 4 = 345 g, already a multiple of 5.
        // Protein: 2760 * 0.20 = 552 kcal, / 4 = 138 g, / 5 = 27.6, rounds to 28, so 140 g.
        // Fat: 2760 * 0.30 = 828 kcal, / 9 = 92 g, / 5 = 18.4, rounds to 18, so 90 g.
        // Fiber: 14 g per 1000 kcal, 2760 * 14 / 1000 = 38.64, rounds to 39 g.
        let target = try estimate(profile())
        XCTAssertEqual(target.carbohydrateGrams, 345)
        XCTAssertEqual(target.proteinGrams, 140)
        XCTAssertEqual(target.fatGrams, 90)
        XCTAssertEqual(target.fiberGrams, 39)
    }

    func testMacroGramsRoundHalfUpToTheNearestFiveGrams() throws {
        // Energy 2450 kcal (the light-activity case above).
        // Carbohydrate: 2450 * 0.50 / 4 = 306.25 g, / 5 = 61.25, rounds to 61, so 305 g.
        // Protein: 2450 * 0.20 / 4 = 122.5 g, / 5 = 24.5, rounds half up to 25, so 125 g.
        // Fat: 2450 * 0.30 / 9 = 81.67 g, / 5 = 16.33, rounds to 16, so 80 g.
        // Fiber: 2450 * 14 / 1000 = 34.3 g, rounds to 34 g.
        let target = try estimate(profile(activity: .light))
        XCTAssertEqual(target.carbohydrateGrams, 305)
        XCTAssertEqual(target.proteinGrams, 125)
        XCTAssertEqual(target.fatGrams, 80)
        XCTAssertEqual(target.fiberGrams, 34)
    }

    func testAnyoneUnder18IsRefused() {
        XCTAssertThrowsError(try GoalEstimator.estimate(profile(age: 17))) { error in
            XCTAssertEqual(error as? GoalEstimateError, .underAge)
        }
        XCTAssertNoThrow(try GoalEstimator.estimate(profile(age: 18)))
    }

    func testEachOutOfRangeFieldIsRefusedByName() {
        func assertRefused(_ profile: GoalProfile, _ field: GoalEstimateField, line: UInt = #line) {
            XCTAssertThrowsError(try GoalEstimator.estimate(profile), line: line) { error in
                XCTAssertEqual(error as? GoalEstimateError, .outOfRange(field), line: line)
            }
        }
        assertRefused(profile(age: 101), .age)
        assertRefused(profile(cm: 119), .height)
        assertRefused(profile(cm: 231), .height)
        assertRefused(profile(kg: 29), .weight)
        assertRefused(profile(kg: 301), .weight)
        assertRefused(profile(aim: .lose, weekly: Decimal(string: "0.05")!), .weeklyChange)
        assertRefused(profile(aim: .gain, weekly: Decimal(string: "1.1")!), .weeklyChange)
    }

    func testTheRangeEndsAreAccepted() {
        XCTAssertNoThrow(try GoalEstimator.estimate(profile(age: 100, cm: 120, kg: 30)))
        XCTAssertNoThrow(try GoalEstimator.estimate(profile(age: 18, cm: 230, kg: 300)))
        XCTAssertNoThrow(try GoalEstimator.estimate(profile(aim: .lose, weekly: Decimal(string: "0.1")!)))
    }

    func testThePaceIsIgnoredWhenMaintaining() throws {
        // A pace is only asked for when losing or gaining, so an out-of-range value does not matter here.
        XCTAssertNoThrow(try GoalEstimator.estimate(profile(aim: .maintain, weekly: 5)))
    }

    func testJustTrackComputesNoTargets() throws {
        XCTAssertNil(try GoalEstimator.estimate(profile(aim: .justTrack)))
        XCTAssertNil(try GoalEstimator.estimate(profile(age: 10, aim: .justTrack)))
    }
}
