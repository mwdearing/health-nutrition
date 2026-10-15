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

    func testTheEraserLeavesAnEmptyCurrentSummaryWithNoFigures() throws {
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        let erasedAt = Date(timeIntervalSince1970: 1_700_000_100)
        try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure(), now: { erasedAt }).eraseAll()
        let after = try XCTUnwrap(store.read())
        // The widget reads "Nothing logged today": no entries, no figures, and it is today's summary.
        XCTAssertFalse(after.hasEntries)
        XCTAssertNil(after.energyKcal)
        XCTAssertNil(after.proteinGrams)
        XCTAssertNil(after.waterMilliliters)
        XCTAssertTrue(after.isCurrent(on: erasedAt))
    }

    func testAWritePendingAtEraseTimeNeverLands() {
        let erasure = WidgetSnapshotErasure()
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let erasedAt = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertTrue(erasure.accepts(loadedAt: before), "no erase yet")
        erasure.markErased(at: erasedAt)
        XCTAssertFalse(erasure.accepts(loadedAt: before), "a load that read the journal before the erase is dropped")
        XCTAssertFalse(erasure.accepts(loadedAt: erasedAt))
        XCTAssertTrue(erasure.accepts(loadedAt: erasedAt.addingTimeInterval(1)), "the reload after the erase publishes")
    }

    func testTheSummaryFileIsExcludedFromBackup() throws {
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        let url = directory.appendingPathComponent(WidgetSnapshotStore.fileName)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
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

    func testFiguresAreWholeNumbersAndHugeOrBrokenValuesAreLeftOut() {
        XCTAssertEqual(WidgetFigure.wholeNumber(1_849.6), "1850")
        XCTAssertEqual(WidgetFigure.wholeNumber(0), "0")
        XCTAssertNil(WidgetFigure.wholeNumber(nil))
        XCTAssertNil(WidgetFigure.wholeNumber(.nan))
        XCTAssertNil(WidgetFigure.wholeNumber(.infinity))
        // Larger than Int.max as a Double: would trap in Int(...) without the bound.
        XCTAssertNil(WidgetFigure.wholeNumber(1e30))
    }
}
