import XCTest
@testable import NutritionDomain

/// The weight plan's rules: which targets each aim needs, which ranges they fall in, the order the
/// checks run in, and the direction the goal must point from the current weight.
final class WeightPlanTests: XCTestCase {
    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text)!
    }

    private func plan(_ aim: GoalAim, goal: String? = nil, pace: String? = nil) -> WeightPlan {
        WeightPlan(
            aim: aim,
            goalKilograms: goal.map { decimal($0) },
            weeklyPaceKilograms: pace.map { decimal($0) })
    }

    /// The error `validate()` throws, or nil when it passes.
    private func thrownError(_ check: () throws -> Void) -> WeightPlanError? {
        do {
            try check()
            return nil
        } catch {
            return error as? WeightPlanError
        }
    }

    func testJustTrackHasNoPlanToValidate() {
        XCTAssertEqual(thrownError { try plan(.justTrack).validate() }, .noPlanForJustTrack)
    }

    func testJustTrackRejectsEvenAGoalAndPaceAsNoPlan() {
        XCTAssertEqual(thrownError { try plan(.justTrack, goal: "80", pace: "0.5").validate() }, .noPlanForJustTrack)
    }

    func testMaintainWithoutTargetsIsValid() {
        XCTAssertNil(thrownError { try plan(.maintain).validate() })
    }

    func testMaintainRejectsAGoal() {
        XCTAssertEqual(thrownError { try plan(.maintain, goal: "80").validate() }, .unexpectedGoal)
    }

    func testMaintainRejectsAPaceWhenNoGoalIsSet() {
        XCTAssertEqual(thrownError { try plan(.maintain, pace: "0.5").validate() }, .unexpectedPace)
    }

    func testMaintainReportsTheGoalBeforeThePace() {
        XCTAssertEqual(thrownError { try plan(.maintain, goal: "80", pace: "0.5").validate() }, .unexpectedGoal)
    }

    func testLoseWithNeitherTargetReportsMissingGoal() {
        XCTAssertEqual(thrownError { try plan(.lose).validate() }, .missingGoal)
    }

    func testGainWithNeitherTargetReportsMissingGoal() {
        XCTAssertEqual(thrownError { try plan(.gain).validate() }, .missingGoal)
    }

    func testLoseWithAGoalButNoPaceReportsMissingPace() {
        XCTAssertEqual(thrownError { try plan(.lose, goal: "80").validate() }, .missingPace)
    }

    func testGainWithAPaceButNoGoalReportsMissingGoal() {
        XCTAssertEqual(thrownError { try plan(.gain, pace: "0.5").validate() }, .missingGoal)
    }

    func testMissingTargetsAreReportedBeforeRangeProblems() {
        // The goal is out of range and the pace is missing: the missing pace comes first.
        XCTAssertEqual(thrownError { try plan(.lose, goal: "29").validate() }, .missingPace)
    }

    func testTheGoalRangeIsCheckedBeforeThePaceRange() {
        XCTAssertEqual(thrownError { try plan(.lose, goal: "29", pace: "2").validate() }, .goalOutOfRange)
    }

    func testWeightRangeEndsAreAccepted() {
        for goal in ["30", "300"] {
            XCTAssertNil(thrownError { try plan(.lose, goal: goal, pace: "0.5").validate() }, goal)
            XCTAssertNil(thrownError { try plan(.gain, goal: goal, pace: "0.5").validate() }, goal)
        }
    }

    func testWeightJustOutsideTheRangeIsRejected() {
        XCTAssertEqual(thrownError { try plan(.lose, goal: "29.9", pace: "0.5").validate() }, .goalOutOfRange)
        XCTAssertEqual(thrownError { try plan(.gain, goal: "300.1", pace: "0.5").validate() }, .goalOutOfRange)
    }

    func testPaceRangeEndsAreAccepted() {
        for pace in ["0.1", "1.0"] {
            XCTAssertNil(thrownError { try plan(.lose, goal: "80", pace: pace).validate() }, pace)
            XCTAssertNil(thrownError { try plan(.gain, goal: "80", pace: pace).validate() }, pace)
        }
    }

    func testPaceJustOutsideTheRangeIsRejected() {
        XCTAssertEqual(thrownError { try plan(.lose, goal: "80", pace: "0.09").validate() }, .paceOutOfRange)
        XCTAssertEqual(thrownError { try plan(.gain, goal: "80", pace: "1.01").validate() }, .paceOutOfRange)
    }

    func testLoseMustPointBelowTheCurrentWeight() {
        XCTAssertEqual(
            thrownError { try plan(.lose, goal: "90", pace: "0.5").validate(currentKilograms: decimal("90")) },
            .goalNotBelowCurrent)
        XCTAssertEqual(
            thrownError { try plan(.lose, goal: "95", pace: "0.5").validate(currentKilograms: decimal("90")) },
            .goalNotBelowCurrent)
        XCTAssertNil(thrownError {
            try plan(.lose, goal: "85", pace: "0.5").validate(currentKilograms: decimal("90"))
        })
    }

    func testGainMustPointAboveTheCurrentWeight() {
        XCTAssertEqual(
            thrownError { try plan(.gain, goal: "80", pace: "0.5").validate(currentKilograms: decimal("80")) },
            .goalNotAboveCurrent)
        XCTAssertEqual(
            thrownError { try plan(.gain, goal: "75", pace: "0.5").validate(currentKilograms: decimal("80")) },
            .goalNotAboveCurrent)
        XCTAssertNil(thrownError {
            try plan(.gain, goal: "85", pace: "0.5").validate(currentKilograms: decimal("80"))
        })
    }

    func testACurrentWeightThatIsNotANumberFailsTheDirectionCheck() {
        // A decimal that is not a number orders below every finite one, so a plain comparison would let a
        // gain through. Neither direction can hold against a current weight that is not a number.
        XCTAssertEqual(
            thrownError { try plan(.gain, goal: "85", pace: "0.5").validate(currentKilograms: .nan) },
            .goalNotAboveCurrent)
        XCTAssertEqual(
            thrownError { try plan(.lose, goal: "75", pace: "0.5").validate(currentKilograms: .nan) },
            .goalNotBelowCurrent)
    }

    func testTheRangeChecksRunBeforeTheDirectionCheck() {
        // 300.1 is out of range and also above a current weight of 90 for a loss plan.
        XCTAssertEqual(
            thrownError { try plan(.lose, goal: "300.1", pace: "0.5").validate(currentKilograms: decimal("90")) },
            .goalOutOfRange)
    }

    func testMaintainNeedsNothingBeyondValidate() {
        XCTAssertNil(thrownError { try plan(.maintain).validate(currentKilograms: decimal("80")) })
    }

    func testStorageTextIsTheFixedSpelling() {
        XCTAssertEqual(GoalAim.lose.storageText, "lose")
        XCTAssertEqual(GoalAim.maintain.storageText, "maintain")
        XCTAssertEqual(GoalAim.gain.storageText, "gain")
        XCTAssertEqual(GoalAim.justTrack.storageText, "just-track")
    }

    func testStorageTextRoundTripsForEveryAim() {
        for aim in [GoalAim.lose, .maintain, .gain, .justTrack] {
            XCTAssertEqual(GoalAim(storageText: aim.storageText), aim)
        }
    }

    func testUnknownStorageTextIsNil() {
        for text in ["justTrack", "", "Lose", "maintain ", "just track", "cut"] {
            XCTAssertNil(GoalAim(storageText: text), text)
        }
    }
}
