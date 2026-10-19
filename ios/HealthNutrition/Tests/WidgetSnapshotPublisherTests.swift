import Foundation
import NutritionDomain
import NutritionJournal
import NutritionUI
import XCTest

@testable import HealthNutrition

/// The publisher's gates against a real Today view model on throwaway files: it writes for the load on screen,
/// and not while an erase runs, for a load announced before an erase, or for a load that is no longer the one on
/// screen. Synthetic data only; display settings live in a throwaway suite.
@MainActor
final class WidgetSnapshotPublisherTests: XCTestCase {
    private let loadedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var directory: URL!

    private func makeToday() throws -> TodayViewModel {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "synthetic.widget.publisher.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { [directory] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let services = try AppServices.make(
            directory: directory.appendingPathComponent("app", isDirectory: true),
            displayPreferences: UserDefaultsDisplayPreferences(defaults: suite),
            reminderScheduler: RecordingReminderScheduler(),
            // Never the real App Group: this test only exercises the publisher against its own store.
            widgetSnapshotEraser: WidgetSnapshotEraser(store: nil, watch: nil))
        return services.today
    }

    private func makeStore() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directory: directory.appendingPathComponent("group", isDirectory: true))
    }

    func testItWritesForTheLoadOnScreen() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: WidgetSnapshotErasure(), watch: nil)
        publisher.publish(from: today, loadedAt: loadedAt, generation: 0)
        XCTAssertEqual(store.read()?.generatedAt, loadedAt)
    }

    func testItWritesNothingForALoadThatIsNoLongerTheOneOnScreen() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: WidgetSnapshotErasure(), watch: nil)
        // A write announced for an earlier load: today.lastLoadedAt has moved on.
        publisher.publish(from: today, loadedAt: loadedAt.addingTimeInterval(-60), generation: 0)
        XCTAssertNil(store.read())
    }

    func testItWritesNothingForALoadAnnouncedBeforeAnErase() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let erasure = WidgetSnapshotErasure()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: erasure, watch: nil)
        let pending = erasure.generation
        erasure.markErased()
        publisher.publish(from: today, loadedAt: loadedAt, generation: pending)
        XCTAssertNil(store.read())
    }

    func testItWritesNothingWhileAnEraseRuns() throws {
        let today = try makeToday()
        today.load(now: loadedAt)
        let store = makeStore()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: WidgetSnapshotErasure(), watch: nil)
        publisher.start(today: today, isErasing: { true })
        XCTAssertNil(store.read(), "the launch-time publish also waits out an erase")
    }

    // MARK: Partial days

    private func line(
        _ amount: NutrientValue, isPartial: Bool = false, knownSum: NutrientValue? = nil
    ) -> NutrientProgressLine {
        NutrientProgressLine(
            nutrient: "protein", amount: amount, goal: nil, isPartial: isPartial, knownSum: knownSum)
    }

    func testAPartialDayPublishesTheKnownSumAndSaysItIsPartial() {
        let partial = line(.unknown, isPartial: true, knownSum: .known(23, .g))
        let figure = WidgetSnapshotPublisher.figure(partial, in: .g)
        XCTAssertEqual(figure.value, 23)
        XCTAssertTrue(figure.isPartial)
    }

    func testAWholeDayPublishesItsTotalAsWhole() {
        let figure = WidgetSnapshotPublisher.figure(line(.known(40, .g)), in: .g)
        XCTAssertEqual(figure.value, 40)
        XCTAssertFalse(figure.isPartial)
    }

    func testAnUnknownFigureIsNilNeverZero() {
        XCTAssertNil(WidgetSnapshotPublisher.figure(line(.unknown), in: .g).value)
        XCTAssertNil(WidgetSnapshotPublisher.figure(nil, in: .g).value)
        // A partial flag with no known sum behind it shows what the whole-day figure is: unknown.
        let nothingKnown = WidgetSnapshotPublisher.figure(line(.unknown, isPartial: true), in: .g)
        XCTAssertNil(nothingKnown.value)
        XCTAssertFalse(nothingKnown.isPartial)
    }

    // MARK: Calories remaining

    func testRemainingBurnedAndPartialAreTakenFromTheModelOnce() {
        let model = CalorieRemaining.make(goal: 2_000, food: 800, partial: true, missingCount: 1, burned: 300, energyLabel: "Energy")
        let figures = WidgetSnapshotPublisher.calorieFigures(model)
        XCTAssertEqual(figures.remaining, 1_500)
        XCTAssertEqual(figures.burned, 300)
        XCTAssertEqual(figures.isPartial, true)
    }

    func testAWholeDayHasNoPartialFlag() {
        let figures = WidgetSnapshotPublisher.calorieFigures(
            CalorieRemaining.make(goal: 2_000, food: 800, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy"))
        XCTAssertEqual(figures.remaining, 1_200)
        XCTAssertNil(figures.burned, "no counted burned means no Burned figure, not zero")
        XCTAssertNil(figures.isPartial)
    }

    func testNoGoalOrNoFoodMeansNoRemainingAndNoPartialFlag() {
        let noGoal = WidgetSnapshotPublisher.calorieFigures(
            CalorieRemaining.make(goal: nil, food: 800, partial: true, missingCount: 1, burned: 200, energyLabel: "Energy"))
        XCTAssertNil(noGoal.remaining)
        XCTAssertNil(noGoal.isPartial, "nothing for a partial flag to qualify")
        XCTAssertEqual(noGoal.burned, 200)
        let noFood = WidgetSnapshotPublisher.calorieFigures(
            CalorieRemaining.make(goal: 2_000, food: nil, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy"))
        XCTAssertNil(noFood.remaining)
        let none = WidgetSnapshotPublisher.calorieFigures(.none)
        XCTAssertNil(none.remaining)
        XCTAssertNil(none.burned)
    }

    func testAnOverspentDayKeepsItsNegativeRemaining() {
        let figures = WidgetSnapshotPublisher.calorieFigures(
            CalorieRemaining.make(goal: 2_000, food: 2_300, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy"))
        XCTAssertEqual(figures.remaining, -300)
    }
}
