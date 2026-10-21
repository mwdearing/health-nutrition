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
    /// The on-screen frame (screen coordinates) and label of the first accessibility element with this identifier. SwiftUI
    /// exposes its accessibility tree as NSObject nodes, not as UIViews, so the walk goes through accessibilityElements.
    private func node(_ identifier: String, in object: NSObject) -> NSObject? {
        if object.accessibilityIdentifier == identifier { return object }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements { children += elements.compactMap { $0 as? NSObject } }
        if !object.isAccessibilityElement {
            for index in 0..<max(0, object.accessibilityElementCount()) {
                if let child = object.accessibilityElement(at: index) as? NSObject { children.append(child) }
            }
        }
        if let view = object as? UIView { children += view.subviews }
        for child in children {
            if let found = node(identifier, in: child) { return found }
        }
        return nil
    }

    private func frame(of identifier: String, in host: UIView) throws -> CGRect {
        let found = try XCTUnwrap(node(identifier, in: host), "\(identifier) is on screen")
        return found.accessibilityFrame
    }

    /// The horizontal centre of the hosted view, in the same screen coordinates as the accessibility frames.
    private func screenCentreX(_ host: UIView) -> CGFloat {
        host.convert(host.bounds, to: nil).midX
    }

    private func hostedToday() throws -> (UIHostingController<AnyView>, UIView, AppServices) {
        let (services, directory) = try makeSeededAppServices()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
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
        let centre = screenCentreX(host)
        for identifier in [
            "todayHeader", "todayDate", "calorieRemainingFigure", "calorieRemainingLabel", "calorieGoalLine",
            "calorieFoodBurnedRow",
        ] {
            let frame = try frame(of: identifier, in: host)
            XCTAssertEqual(frame.midX, centre, accuracy: 1, identifier)
        }
    }

    func testTheGoalLineReadsWithItsThousandsSeparator() throws {
        let (_, host, _) = try hostedToday()
        let goal = try XCTUnwrap(node("calorieGoalLine", in: host))
        XCTAssertEqual(goal.accessibilityLabel, "of 2,357 Calories goal")
    }

    func testEachMacroLabelAndFigureIsCentredInItsOwnEqualColumn() throws {
        let (_, host, _) = try hostedToday()
        var widths: [CGFloat] = []
        for nutrient in ["Protein", "Carbohydrate", "Fat"] {
            let column = try frame(of: "macroColumn-\(nutrient)", in: host)
            let label = try frame(of: "macroLabel-\(nutrient)", in: host)
            let figure = try frame(of: "macroFigure-\(nutrient)", in: host)
            XCTAssertEqual(label.midX, column.midX, accuracy: 1, "\(nutrient) label")
            XCTAssertEqual(figure.midX, column.midX, accuracy: 1, "\(nutrient) figure")
            widths.append(column.width)
        }
        let first = try XCTUnwrap(widths.first)
        for width in widths {
            XCTAssertEqual(width, first, accuracy: 1, "the three macro columns are equal width")
        }
    }
}
