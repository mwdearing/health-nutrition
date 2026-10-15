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

    func testIfTheEmptyWriteFailsTheFileIsRemovedSoNoFigureIsLeftBehind() throws {
        var store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        XCTAssertNotNil(store.read())
        struct WriteFailed: Error {}
        store.writeData = { _, _ in throw WriteFailed() }
        try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure()).eraseAll()
        XCTAssertNil(store.read())
    }

    func testIfBothTheEmptyWriteAndTheRemovalFailTheFileIsEmptiedInPlace() throws {
        final class FailingRemoval: FileManager {
            struct Failed: Error {}
            override func removeItem(at URL: URL) throws { throw Failed() }
        }
        var store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        struct WriteFailed: Error {}
        store.writeData = { _, _ in throw WriteFailed() }
        store.fileManager = FailingRemoval()
        try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure()).eraseAll()
        // No figure is left: the widget cannot decode an empty file and shows dashes.
        XCTAssertNil(store.read())
        let url = folder.appendingPathComponent(WidgetSnapshotStore.fileName)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    private var folder: URL { directory.appendingPathComponent(WidgetSnapshotStore.folderName) }

    func testAWriteLeavesOnlyTheSummaryInItsOwnFolderAndEraseRemovesTheFolderWithAnyTemporary() throws {
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [WidgetSnapshotStore.folderName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [WidgetSnapshotStore.fileName])
        // An interrupted write leaves the fixed temporary name behind; launch cleanup, and erase, remove it.
        let leftover = folder.appendingPathComponent(WidgetSnapshotStore.fileName + ".tmp")
        try Data("figures".utf8).write(to: leftover)
        store.removeStaleTemporary()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        try Data("figures".utf8).write(to: leftover)
        try store.erase()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testTheFolderIsExcludedFromBackupSoNothingInsideItCanBeBackedUp() throws {
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testTheSummaryFileReadsBackAsExcludedToo() throws {
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        try store.write(sample())  // the replace path as well as the first move
        let file = folder.appendingPathComponent(WidgetSnapshotStore.fileName)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testEraseAlsoRemovesASummaryAnEarlierBuildKeptInTheContainerRoot() throws {
        let store = WidgetSnapshotStore(directory: directory)
        let legacy = directory.appendingPathComponent(WidgetSnapshotStore.fileName)
        try Data("figures".utf8).write(to: legacy)
        try store.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testAFolderThatCannotBeLeftOutOfBackupsIsNotLeftOnDisk() throws {
        var store = WidgetSnapshotStore(directory: directory)
        struct Refused: Error {}
        store.excludeFromBackup = { _ in throw Refused() }
        XCTAssertThrowsError(try store.write(sample()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testAFailedWriteLeavesThePreviousSummaryAsItWas() throws {
        var store = WidgetSnapshotStore(directory: directory)
        try store.write(sample())
        struct WriteFailed: Error {}
        store.writeData = { _, _ in throw WriteFailed() }
        XCTAssertThrowsError(try store.write(WidgetSnapshot.empty(at: Date())))
        XCTAssertEqual(store.read(), sample())
    }

    func testAWritePendingAtEraseTimeNeverLandsWhateverTheClockDoes() {
        let erasure = WidgetSnapshotErasure()
        let pending = erasure.generation
        XCTAssertTrue(erasure.accepts(generation: pending), "no erase yet")
        erasure.markErased()
        XCTAssertFalse(erasure.accepts(generation: pending), "a load announced before the erase is dropped")
        XCTAssertTrue(erasure.accepts(generation: erasure.generation), "the reload after the erase publishes")
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
