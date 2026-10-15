import Combine
import Foundation
import NutritionDomain
import XCTest

@testable import HealthNutrition

final class WidgetSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample() -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), hasEntries: true, energyKcal: 1_050,
            energyGoalKcal: 2_100, proteinGrams: 80, carbohydrateGrams: 120, fatGrams: 40, waterMilliliters: 750)
    }

    func testTheAppGroupIsNamedAfterTheAppAndTheExtensionResolvesToTheSameGroup() {
        let app = WidgetAppGroup.identifier(forBundleIdentifier: "dev.example.HealthNutrition", isExtension: false)
        let widgets = WidgetAppGroup.identifier(
            forBundleIdentifier: "dev.example.HealthNutrition.widgets", isExtension: true)
        XCTAssertEqual(app, "group.dev.example.HealthNutrition")
        XCTAssertEqual(widgets, app)
    }

    func testAnAppIdentifierThatEndsInWidgetsKeepsItInTheAppAndLosesOnlyTheExtensionsOwnSuffix() {
        let app = WidgetAppGroup.identifier(forBundleIdentifier: "dev.example.nutrition.widgets", isExtension: false)
        let widgets = WidgetAppGroup.identifier(
            forBundleIdentifier: "dev.example.nutrition.widgets.widgets", isExtension: true)
        XCTAssertEqual(app, "group.dev.example.nutrition.widgets")
        XCTAssertEqual(widgets, app)
    }

    func testASnapshotRoundTripsThroughTheFile() throws {
        let store = WidgetSnapshotStore(directory: directory)
        XCTAssertNil(store.read())
        try store.write(sample())
        XCTAssertEqual(store.read(), sample())
    }

    func testEraseRemovesTheSnapshotAndIsHarmlessWithoutOne() throws {
        let store = WidgetSnapshotStore(directory: directory)
        try store.erase()
        try store.write(sample())
        try store.erase()
        XCTAssertNil(store.read())
    }

    func testTheEraserRemovesTheSnapshotWithTheRestOfTheData() throws {
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        try WidgetSnapshotEraser(store: store).eraseAll()
        XCTAssertNil(store.read())
    }

    func testEnergyFractionNeedsAKnownTotalAndAGoalAndNeverExceedsOne() {
        var snapshot = sample()
        XCTAssertEqual(snapshot.energyFraction ?? -1, 0.5, accuracy: 0.0001)
        snapshot.energyKcal = 5_000
        XCTAssertEqual(snapshot.energyFraction, 1)
        snapshot.energyKcal = nil
        XCTAssertNil(snapshot.energyFraction)
        snapshot.energyKcal = 100
        snapshot.energyGoalKcal = 0
        XCTAssertNil(snapshot.energyFraction)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testASummaryFromEarlierTodayIsCurrentAndYesterdaysIsNot() {
        var snapshot = sample()
        // 2023-11-14 22:13:20 UTC.
        let evening = Date(timeIntervalSince1970: 1_700_000_000)
        snapshot.generatedAt = evening
        XCTAssertTrue(snapshot.isCurrent(on: evening.addingTimeInterval(60 * 60), calendar: utc))
        // Just after midnight, with the app closed: still yesterday's summary.
        XCTAssertFalse(snapshot.isCurrent(on: evening.addingTimeInterval(3 * 60 * 60), calendar: utc))
    }

    func testTheRefreshIsJustAfterTheNextLocalMidnight() {
        let evening = Date(timeIntervalSince1970: 1_700_000_000)
        let refresh = WidgetSnapshot.refreshAfterMidnight(from: evening, calendar: utc)
        // 2023-11-15 00:01:00 UTC.
        XCTAssertEqual(refresh, Date(timeIntervalSince1970: 1_700_006_460))
    }

    func testAMilligramTotalIsConvertedToGramsBeforeItIsWritten() {
        XCTAssertEqual(WidgetSnapshotUnits.value(Quantity(value: 500, unit: .mg), in: .g) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(WidgetSnapshotUnits.value(Quantity(value: 2, unit: .kg), in: .g) ?? -1, 2_000, accuracy: 1e-9)
        XCTAssertEqual(WidgetSnapshotUnits.value(Quantity(value: 42, unit: .g), in: .g), 42)
    }

    func testAValueThatCannotBeConvertedIsLeftOut() {
        // Volume to mass needs a density the snapshot does not have.
        XCTAssertNil(WidgetSnapshotUnits.value(Quantity(value: 10, unit: .mL), in: .g))
    }

    func testNothingIsPublishedWhileTodayReportsAnError() {
        XCTAssertTrue(WidgetSnapshotPublisher.shouldPublish(errorMessage: nil, hasLoaded: true))
        XCTAssertFalse(
            WidgetSnapshotPublisher.shouldPublish(errorMessage: "Could not read the journal.", hasLoaded: true))
    }

    func testNothingIsPublishedBeforeTheFirstSuccessfulLoad() {
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPublish(errorMessage: nil, hasLoaded: false))
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPublish(errorMessage: "Could not read the journal.", hasLoaded: false))
    }

    func testFiguresAreWholeNumbersAndHugeOrBrokenValuesAreLeftOut() {
        XCTAssertEqual(WidgetFigure.wholeNumber(1_849.6), "1850")
        XCTAssertEqual(WidgetFigure.wholeNumber(0), "0")
        XCTAssertNil(WidgetFigure.wholeNumber(nil))
        XCTAssertNil(WidgetFigure.wholeNumber(.nan))
        XCTAssertNil(WidgetFigure.wholeNumber(.infinity))
        // Larger than Int.max as a Double: would trap in Int(...) without the bound.
        XCTAssertNil(WidgetFigure.wholeNumber(1e30))
    }

    func testASnapshotIsStampedWithTheTimeOfTheChangeNotTheTimeItIsDelivered() {
        let subject = PassthroughSubject<Void, Never>()
        var clock = Date(timeIntervalSince1970: 1_700_006_399)  // 2023-11-14 23:59:59 UTC
        var received: [Date] = []
        let done = expectation(description: "delivered after the debounce")
        let cancellable = WidgetSnapshotPublisher
            .emissionTimes(of: subject, debounce: .milliseconds(20), now: { clock })
            .sink { time in
                received.append(time)
                done.fulfill()
            }
        subject.send()
        // The debounce delivers after midnight: the clock has moved on, the stamp must not.
        clock = Date(timeIntervalSince1970: 1_700_006_401)  // 00:00:01 UTC
        wait(for: [done], timeout: 2)
        cancellable.cancel()
        XCTAssertEqual(received, [Date(timeIntervalSince1970: 1_700_006_399)])
    }
}
