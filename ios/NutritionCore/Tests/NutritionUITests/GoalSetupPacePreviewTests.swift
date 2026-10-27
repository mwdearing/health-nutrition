import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The pace step of goal setup shows the day the chosen pace reaches the goal weight, in the same words
/// as Today's plan line. Plain numbers only.
@MainActor
final class GoalSetupPacePreviewTests: XCTestCase {
    /// 2026-04-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)

    private func calendar(_ identifier: Calendar.Identifier = .gregorian, zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func makeModel(
        system: UnitSystem = .metric, calendar: Calendar? = nil, now: (() -> Date)? = nil
    ) -> GoalSetupViewModel {
        let goals = GoalsViewModel(
            store: GoalSetupPlanStore(), preferences: InMemoryDisplayPreferences(unitSystem: system))
        goals.load()
        let fixed = self.now
        return GoalSetupViewModel(goals: goals, now: now ?? { fixed }, calendar: calendar ?? self.calendar())
    }

    /// A man of 30, 180 cm and 80 kg (5 ft 11 in and 176 lb), moderately active, on the pace step.
    private func answer(_ model: GoalSetupViewModel, aim: GoalAim, system: UnitSystem = .metric) {
        model.aim = aim
        model.sex = .male
        model.ageText = "30"
        if system == .usCustomary {
            model.heightFeetText = "5"
            model.heightInchesText = "11"
            model.weightPoundsText = "176"
        } else {
            model.heightCentimetersText = "180"
            model.weightKilogramsText = "80"
        }
        model.activity = .moderate
        var moves = 0
        while model.step != .pace, model.canGoNext, moves < 10 {
            model.next()
            moves += 1
        }
        XCTAssertEqual(model.step, .pace)
    }

    private func pace(_ model: GoalSetupViewModel, _ label: String) {
        model.selectedPaceKilograms = model.paceOptions.first(where: { $0.label == label })?.kilogramsPerWeek
        XCTAssertNotNil(model.selectedPaceKilograms, label)
    }

    func testALossShowsTheDayThePaceReachesTheGoal() {
        let model = makeModel()
        answer(model, aim: .lose)
        pace(model, "0.5 kg per week")
        model.goalWeightKilogramsText = "75"

        // 5 kg at 0.5 kg a week is 70 days from April 15.
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on Jun 24, 2026")
    }

    func testPartDaysRoundUp() {
        let model = makeModel()
        answer(model, aim: .lose)
        pace(model, "0.75 kg per week")
        model.goalWeightKilogramsText = "79"

        // 1 kg at 0.75 kg a week is 9.33 days, so 10.
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 79 kg on Apr 25, 2026")
    }

    func testAGainShowsTheDayToo() {
        let model = makeModel()
        answer(model, aim: .gain)
        pace(model, "0.25 kg per week")
        model.goalWeightKilogramsText = "82.5"

        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 82.5 kg on Jun 24, 2026")
    }

    func testPoundsShowTheGoalInPounds() {
        let model = makeModel(system: .usCustomary)
        answer(model, aim: .lose, system: .usCustomary)
        pace(model, "1 lb per week")
        model.goalWeightPoundsText = "166"

        // 10 lb at 1 lb a week is 70 days.
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 166 lb on Jun 24, 2026")
    }

    func testTheLineFollowsThePaceAndGoalAsTheyChange() {
        let model = makeModel()
        answer(model, aim: .lose)
        pace(model, "0.5 kg per week")
        model.goalWeightKilogramsText = "75"
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on Jun 24, 2026")

        pace(model, "1 kg per week")
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on May 20, 2026")

        model.goalWeightKilogramsText = "70"
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 70 kg on Jun 24, 2026")
    }

    func testNoLineUntilThePaceAndAValidGoalAreThere() {
        let model = makeModel()
        answer(model, aim: .lose)
        XCTAssertNil(model.paceGoalDayText)

        model.goalWeightKilogramsText = "75"
        XCTAssertNil(model.paceGoalDayText, "no pace chosen yet")

        pace(model, "0.5 kg per week")
        model.goalWeightKilogramsText = ""
        XCTAssertNil(model.paceGoalDayText, "no goal weight yet")

        model.goalWeightKilogramsText = "85"
        XCTAssertNotNil(model.goalWeightNotice)
        XCTAssertNil(model.paceGoalDayText, "a goal above the current weight while losing")

        model.goalWeightKilogramsText = "abc"
        XCTAssertNil(model.paceGoalDayText, "an unreadable goal weight")
    }

    func testMaintainAndJustTrackShowNoLine() {
        for aim in [GoalAim.maintain, .justTrack] {
            let model = makeModel()
            model.aim = aim
            model.weightKilogramsText = "80"
            model.goalWeightKilogramsText = "75"
            model.selectedPaceKilograms = Decimal(string: "0.5")!
            XCTAssertNil(model.paceGoalDayText, "\(aim)")
        }
    }

    func testTodayIsTheDayInTheCalendarsTimeZone() {
        // 12:00 UTC on April 15 is already 02:00 on April 16 at UTC+14.
        let model = makeModel(calendar: calendar(zone: "Pacific/Kiritimati"))
        answer(model, aim: .lose)
        pace(model, "0.5 kg per week")
        model.goalWeightKilogramsText = "75"

        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on Jun 25, 2026")
    }

    func testDaysAreGregorianOnADeviceSetToAnotherCalendar() {
        let model = makeModel(calendar: calendar(.buddhist))
        answer(model, aim: .lose)
        pace(model, "0.5 kg per week")
        model.goalWeightKilogramsText = "75"

        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on Jun 24, 2026")
    }

    func testEachReadUsesTheCurrentTime() {
        var current = now
        let model = makeModel(now: { current })
        answer(model, aim: .lose)
        pace(model, "0.5 kg per week")
        model.goalWeightKilogramsText = "75"
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on Jun 24, 2026")

        current = now.addingTimeInterval(86_400)
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on Jun 25, 2026")
    }

    func testTheLineMatchesTodaysPlanLine() {
        let model = makeModel()
        answer(model, aim: .lose)
        pace(model, "0.5 kg per week")
        model.goalWeightKilogramsText = "75"

        let day = PlanProjection.goalDay(
            currentKilograms: 80, goalKilograms: 75, weeklyPaceKilograms: Decimal(string: "0.5")!,
            from: CalendarDay(iso: "2026-04-15")!)!
        XCTAssertEqual(model.paceGoalDayText, "Plan reaches 75 kg on \(BodyActivityViewModel.dayText(day))")
    }

    func testNoLineGradesThePace() {
        let model = makeModel()
        answer(model, aim: .lose)
        pace(model, "1 kg per week")
        model.goalWeightKilogramsText = "75"

        let line = (model.paceGoalDayText ?? "").lowercased()
        XCTAssertFalse(line.isEmpty)
        for word in ["ahead", "behind", "on track", "off track", "great", "good", "bad", "slow", "fast", "safe", "healthy"] {
            XCTAssertFalse(line.contains(word), word)
        }
    }
}
