import Foundation
import NutritionDomain
import NutritionJournal
import NutritionUI
import XCTest

@testable import HealthNutrition

private final class ReadFailingStoreStub: JournalStore, @unchecked Sendable {
    var failNextSaveForTesting = false
    let intakes: [Intake]
    let components: [String: [IntakeComponent]]

    init(intakes: [Intake], components: [String: [IntakeComponent]]) {
        self.intakes = intakes
        self.components = components
    }

    private struct Unsupported: Error {}

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        throw Unsupported()
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        throw Unsupported()
    }

    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil, unitRemovals: [String])throws -> IntakeRevision {
        throw Unsupported()
    }
    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    var failReadsForTesting = false
    func activeIntakes() throws -> [Intake] {
        if failReadsForTesting { throw Unsupported() }
        return intakes
    }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        [IntakeRevision(
            intakeID: intakeID, number: 1, components: components[intakeID] ?? [], productSnapshotID: nil,
            changeReason: "test", createdAt: Date(timeIntervalSince1970: 0))]
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { nil }
    func activeIntakesFromBackground() async throws -> [Intake] {
        if failReadsForTesting { throw Unsupported() }
        return intakes
    }
    func close() {}
}

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

    /// A Today model that has not read the journal has no water total, so the snapshot writes nil, never 0, and the
    /// widget draws a dash for it.
    func testAModelWithoutAReadWritesNilWaterAndTheWidgetShowsADash() throws {
        let today = try makeToday()

        let snapshot = WidgetSnapshotPublisher.snapshot(from: today, now: loadedAt)

        XCTAssertNil(snapshot.waterMilliliters, "no read means no water total, not zero")
        XCTAssertEqual(WidgetFigure.water(snapshot.waterMilliliters, usUnits: false), "—")
        XCTAssertEqual(WidgetFigure.water(snapshot.waterMilliliters, usUnits: true), "—")
    }

    /// A journal read that fails writes no widget summary, so yesterday's or an empty day is never shown as today.
    func testItWritesNothingWhenTheJournalReadFails() throws {
        _ = try makeToday()
        let store = ReadFailingStoreStub(intakes: [], components: [:])
        store.failReadsForTesting = true
        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: loadedAt)
        XCTAssertTrue(today.journalReadFailed)
        let widgetStore = makeStore()
        let publisher = WidgetSnapshotPublisher(store: widgetStore, erasure: WidgetSnapshotErasure(), watch: nil)

        publisher.publish(from: today, loadedAt: loadedAt, generation: 0)

        XCTAssertNil(widgetStore.read(), "a failed read writes no summary")
    }

    /// A model that never read the journal is not an empty day: the publisher writes nothing for it.
    func testItWritesNothingBeforeAnyRead() throws {
        let today = try makeToday()
        let store = makeStore()
        let publisher = WidgetSnapshotPublisher(store: store, erasure: WidgetSnapshotErasure(), watch: nil)
        publisher.publish(from: today, loadedAt: loadedAt, generation: 0)
        XCTAssertNil(store.read(), "no read means no summary, so no empty day is written")
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
