import NutritionDomain
import NutritionJournal
import NutritionUI
import SwiftUI
import UIKit
import XCTest

@testable import HealthNutrition

/// The Today summary is centred on the screen: the title, the date, the calorie figure, its label and goal line, the
/// Food row, and each macro label and figure centred in its own column. Measured on a seeded day with a calorie goal.
@MainActor
final class TodayCentringTests: XCTestCase {
    /// The on-screen view with this identifier, if any, found by walking the hosted view tree.
    private func element(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews {
            if let found = element(identifier, in: subview) { return found }
        }
        return nil
    }

    /// The horizontal centre of a view, in the hosting view's coordinates.
    private func centreX(_ view: UIView, in host: UIView) -> CGFloat {
        view.convert(view.bounds, to: host).midX
    }

    private func hostedToday() throws -> (UIHostingController<AnyView>, UIView, AppServices) {
        let services = try makeSeededAppServices()
        try services.goalStore.setGoal(NutrientGoal(nutrient: "energy", target: 2357, unit: .kcal))
        try services.goalStore.setGoal(NutrientGoal(nutrient: "carbohydrate", target: 250, unit: .g))
        try services.goalStore.setGoal(NutrientGoal(nutrient: "fat", target: 70, unit: .g))
        services.today.load(now: Date())
        let root = AnyView(TodayView(model: services.today, onAddIntake: {}).frame(width: 390))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (host, host.view, services)
    }

    func testTheTitleDateAndCalorieBlockAreCentredOnTheScreen() throws {
        let (_, host, _) = try hostedToday()
        let centre = host.bounds.midX
        for identifier in [
            "todayHeader", "todayDate", "calorieRemainingFigure", "calorieRemainingLabel", "calorieGoalLine",
            "calorieFoodBurnedRow",
        ] {
            let view = try XCTUnwrap(element(identifier, in: host), "\(identifier) is on screen")
            XCTAssertEqual(centreX(view, in: host), centre, accuracy: 1, identifier)
        }
    }

    func testTheGoalLineReadsWithItsThousandsSeparator() throws {
        let (_, host, _) = try hostedToday()
        let goal = try XCTUnwrap(element("calorieGoalLine", in: host))
        XCTAssertEqual(goal.accessibilityLabel, "of 2,357 Calories goal")
    }

    func testEachMacroLabelAndFigureIsCentredInItsOwnEqualColumn() throws {
        let (_, host, _) = try hostedToday()
        var widths: [CGFloat] = []
        for nutrient in ["Protein", "Carbohydrate", "Fat"] {
            let column = try XCTUnwrap(element("macroColumn-\(nutrient)", in: host), "\(nutrient) column is on screen")
            let label = try XCTUnwrap(element("macroLabel-\(nutrient)", in: host))
            let figure = try XCTUnwrap(element("macroFigure-\(nutrient)", in: host))
            XCTAssertEqual(centreX(label, in: host), centreX(column, in: host), accuracy: 1, "\(nutrient) label")
            XCTAssertEqual(centreX(figure, in: host), centreX(column, in: host), accuracy: 1, "\(nutrient) figure")
            widths.append(column.convert(column.bounds, to: host).width)
        }
        let first = try XCTUnwrap(widths.first)
        for width in widths {
            XCTAssertEqual(width, first, accuracy: 1, "the three macro columns are equal width")
        }
    }
}
