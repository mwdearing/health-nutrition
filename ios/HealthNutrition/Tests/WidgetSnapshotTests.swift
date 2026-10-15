import Foundation
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
        let app = WidgetAppGroup.identifier(forBundleIdentifier: "dev.example.HealthNutrition")
        let widgets = WidgetAppGroup.identifier(forBundleIdentifier: "dev.example.HealthNutrition.widgets")
        XCTAssertEqual(app, "group.dev.example.HealthNutrition")
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
}
