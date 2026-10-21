import NutritionUI
import UIKit
import XCTest

@testable import HealthNutrition

/// The calorie summary block is centred on the screen: its Food figure's centre is the centre of the view.
@MainActor
final class TodayCentringTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// The on-screen frame, in the hosting view's coordinates, of the first accessibility element with this identifier.
    private func frame(of identifier: String, in view: UIView) -> CGRect? {
        if view.accessibilityIdentifier == identifier {
            return view.convert(view.bounds, to: nil)
        }
        for subview in view.subviews {
            if let found = frame(of: identifier, in: subview) { return found }
        }
        return nil
    }

    func testTheCalorieFoodFigureIsCentredOnTheScreen() throws {
        let model = TodayViewModel(store: try makeJournal(), timeZoneIdentifier: "UTC")
        model.load(now: now)
        let host = UIHostingController(rootView: NourishTodayHeader(model: model).frame(width: 390))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        let food = try XCTUnwrap(frame(of: "calorieFoodLabel", in: host.view), "the Food figure is on screen")
        XCTAssertEqual(food.midX, host.view.bounds.midX, accuracy: 1)
    }
}
