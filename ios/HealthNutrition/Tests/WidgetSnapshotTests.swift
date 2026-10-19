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

    /// "Nothing logged today" is shown only for a summary for today with no entries, never for a missing summary.
    func testNothingIsLoggedOnlyForACurrentEmptySummary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let current = WidgetSnapshot.empty(at: now)

        XCTAssertTrue(current.isCurrent(on: now))
        XCTAssertTrue(WidgetSnapshot.showsNothingLogged(current))
        XCTAssertFalse(WidgetSnapshot.showsNothingLogged(nil), "no summary says nothing about the day")
    }

    func testTheAppGroupIsNamedAfterTheAppAndTheExtensionResolvesToTheSameGroup() {
        let app = WidgetAppGroup.identifier(forBundleIdentifier: "dev.example.HealthNutrition", isExtension: false)
        let widgets = WidgetAppGroup.identifier(
            forBundleIdentifier: "dev.example.HealthNutrition.widgets", isExtension: true)
        XCTAssertEqual(app, "group.dev.example.HealthNutrition")
        XCTAssertEqual(widgets, app)
    }

    func testWaterIsDrawnInFluidOuncesUnderUSUnitsAndMillilitresOtherwise() {
        XCTAssertEqual(WidgetFigure.water(1_000, usUnits: true), "34 fl oz")
        XCTAssertEqual(WidgetFigure.water(1_000, usUnits: false), "1000 mL")
        XCTAssertEqual(WidgetFigure.water(1_000, usUnits: nil), "1000 mL", "a summary from before the field is metric")
        XCTAssertEqual(WidgetFigure.water(0, usUnits: true), "0 fl oz")
        XCTAssertEqual(WidgetFigure.water(10, usUnits: true), "<1 fl oz", "a sip is not zero")
        XCTAssertEqual(WidgetFigure.water(15, usUnits: true), "1 fl oz")
        XCTAssertEqual(WidgetFigure.water(nil, usUnits: true), "—")
        XCTAssertEqual(WidgetFigure.water(.infinity, usUnits: true), "—")
        XCTAssertEqual(WidgetFigure.water(nil, usUnits: nil), "— mL")
    }

    func testASummaryWithoutTheCalorieFieldsDecodesAndTheNewFieldsRoundTrip() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = Data(#"{"generatedAt":"2023-11-14T22:13:20Z","hasEntries":true,"energyKcal":1}"#.utf8)
        let decoded = try decoder.decode(WidgetSnapshot.self, from: old)
        XCTAssertNil(decoded.remainingKcal)
        XCTAssertNil(decoded.burnedKcal)
        XCTAssertNil(decoded.remainingIsPartial)
        var snapshot = WidgetSnapshot.empty(at: Date(timeIntervalSince1970: 1_700_000_000))
        snapshot.remainingKcal = -300
        snapshot.burnedKcal = 250
        snapshot.remainingIsPartial = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot)), snapshot)
    }

    func testPartialMacroFiguresStillGetAPlus() {
        XCTAssertEqual(WidgetFigure.figure(23, unit: "g", partial: true), "23+ g")
        XCTAssertEqual(WidgetFigure.figure(23, unit: "g"), "23 g")
        XCTAssertEqual(WidgetFigure.number(0, partial: true), "0+")
        XCTAssertEqual(WidgetFigure.number(nil, partial: true), "—", "nothing known stays a dash")
    }

    func testTheCalorieBlockIsWordedAsTodayWordsIt() throws {
        var snapshot = WidgetSnapshot.empty(at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(snapshot.remainingText)
        XCTAssertEqual(snapshot.calorieSpoken, "Calories unknown")
        snapshot.energyKcal = 800
        snapshot.remainingKcal = 1_200
        snapshot.burnedKcal = 250
        let grouped = { (value: Double) in value.formatted(.number.precision(.fractionLength(0))) }
        XCTAssertEqual(snapshot.remainingText, grouped(1_200))
        XCTAssertEqual(snapshot.foodText, "800")
        XCTAssertEqual(snapshot.burnedText, "250")
        XCTAssertEqual(
            snapshot.calorieSpoken,
            "\(grouped(1_200)) calories remaining, Food, 800 calories, Burned, 250 calories")
        // Over goal is a plain negative number, with no word for it.
        snapshot.remainingKcal = -150
        XCTAssertEqual(snapshot.remainingText, grouped(-150))
        let negative = try XCTUnwrap(snapshot.remainingText)
        XCTAssertTrue(negative.hasPrefix("-") || negative.hasPrefix("\u{2212}"), "a plain negative number")
        // Without a goal there is no Remaining; without a burned value there is no Burned.
        snapshot.remainingKcal = nil
        snapshot.burnedKcal = nil
        XCTAssertEqual(WidgetFigure.groupedWholeNumber(-0.4), grouped(0), "never \"-0\"")
        XCTAssertNil(WidgetFigure.groupedWholeNumber(.infinity))
        XCTAssertNil(WidgetFigure.groupedWholeNumber(nil))
        XCTAssertNil(snapshot.remainingText)
        XCTAssertNil(snapshot.burnedText)
        XCTAssertEqual(snapshot.calorieSpoken, "Food, 800 calories")
    }

    func testAPartialDayMarksFoodAndRemainingAsApproved() throws {
        let grouped = { (value: Double) in value.formatted(.number.precision(.fractionLength(0))) }
        var snapshot = WidgetSnapshot.empty(at: Date(timeIntervalSince1970: 1_700_000_000))
        snapshot.energyKcal = 800
        snapshot.remainingKcal = 1_200
        snapshot.burnedKcal = 250
        snapshot.partialFigures = ["energy"]
        snapshot.remainingIsPartial = true
        // Food is "N+", spoken "at least"; Remaining is "Up to N", spoken "up to".
        XCTAssertEqual(snapshot.foodText, "800+")
        XCTAssertEqual(snapshot.remainingDisplay, "Up to \(grouped(1_200))")
        XCTAssertEqual(snapshot.remainingInlineText, "up to \(grouped(1_200))")
        XCTAssertEqual(
            snapshot.calorieSpoken,
            "up to \(grouped(1_200)) calories remaining, Food, at least 800 calories, Burned, 250 calories")
        // The gauge holds Food ("800+"), matching its ring, which is the share of the goal eaten.
        XCTAssertEqual(snapshot.gaugeHeadline, "800+")
        // Burned never gets a marker.
        XCTAssertEqual(snapshot.burnedText, "250")
        // At or below zero while partial: a plain negative number, no marker.
        snapshot.remainingKcal = -150
        XCTAssertFalse(snapshot.remainingIsUpperBound)
        XCTAssertEqual(snapshot.remainingDisplay, grouped(-150))
        XCTAssertEqual(snapshot.gaugeHeadline, "800+")
        XCTAssertTrue(snapshot.calorieSpoken.hasPrefix("\(grouped(-150)) calories remaining"))
        snapshot.remainingKcal = 0
        XCTAssertFalse(snapshot.remainingIsUpperBound)
        // A whole day has no markers at all.
        snapshot.remainingKcal = 1_200
        snapshot.remainingIsPartial = nil
        snapshot.partialFigures = nil
        XCTAssertEqual(snapshot.foodText, "800")
        XCTAssertEqual(snapshot.remainingDisplay, grouped(1_200))
        XCTAssertEqual(snapshot.gaugeHeadline, "800")
    }

    func testOnlyTheListedFiguresAreTreatedAsPartial() {
        var snapshot = WidgetSnapshot.empty(at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(snapshot.isPartial("energy"))
        snapshot.partialFigures = ["energy", "fat"]
        XCTAssertTrue(snapshot.isPartial("energy"))
        XCTAssertTrue(snapshot.isPartial("fat"))
        XCTAssertFalse(snapshot.isPartial("protein"))
    }

    func testASummaryWrittenBeforeTheUnitFieldStillDecodes() throws {
        let old = Data(
            #"{"generatedAt":"2023-11-14T22:13:20Z","hasEntries":true,"energyKcal":1,"waterMilliliters":2}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: old)
        XCTAssertNil(snapshot.usUnits)
        XCTAssertEqual(snapshot.waterMilliliters, 2)
    }

    func testTheWatchAppAndItsWidgetsResolveToTheSameGroupAsThePhoneApp() {
        let app = WidgetAppGroup.identifier(forBundleIdentifier: "dev.example.HealthNutrition", isExtension: false)
        let watch = WidgetAppGroup.identifier(
            forBundleIdentifier: "dev.example.HealthNutrition.watchkitapp", isExtension: false, isWatch: true)
        let watchWidgets = WidgetAppGroup.identifier(
            forBundleIdentifier: "dev.example.HealthNutrition.watchkitapp.widgets", isExtension: true, isWatch: true)
        XCTAssertEqual(watch, app)
        XCTAssertEqual(watchWidgets, app)
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
        try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure(), watch: nil, now: { erasedAt }).eraseAll()
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
        try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure(), watch: nil).eraseAll()
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
        try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure(), watch: nil).eraseAll()
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

    func testTheEraserRemovesALegacyRootSummaryEvenWhenTheEmptyWriteSucceeds() throws {
        let store = WidgetSnapshotStore(directory: directory)
        let legacy = directory.appendingPathComponent(WidgetSnapshotStore.fileName)
        try Data("figures".utf8).write(to: legacy)
        try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure(), watch: nil).eraseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertNotNil(store.read(), "the empty summary was written")
    }

    func testALegacyRootSummaryThatCannotBeRemovedMakesTheEraseReportFailureAfterTheFolderIsEmptied() throws {
        final class LegacyRefusing: FileManager {
            struct Refused: Error {}
            var protected: URL?
            override func removeItem(at URL: URL) throws {
                if URL.path == protected?.path { throw Refused() }
                try super.removeItem(at: URL)
            }
        }
        let manager = LegacyRefusing()
        var store = WidgetSnapshotStore(directory: directory)
        store.fileManager = manager
        let legacy = directory.appendingPathComponent(WidgetSnapshotStore.fileName)
        manager.protected = legacy
        try Data("figures".utf8).write(to: legacy)
        try store.write(sample())
        XCTAssertThrowsError(try WidgetSnapshotEraser(store: store, erasure: WidgetSnapshotErasure(), watch: nil).eraseAll())
        XCTAssertThrowsError(try store.removeLegacyRootFiles())
        // The folder's summary was still emptied, and the failure is not swallowed.
        XCTAssertEqual(store.read()?.hasEntries, false)
        manager.protected = nil
        try store.removeLegacyRootFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testNextMidnightIsTheStartOfTheFollowingLocalDay() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let evening = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 21, minute: 30)))
        let midnight = WidgetSnapshot.nextMidnight(from: evening, calendar: utc)
        XCTAssertEqual(utc.dateComponents([.year, .month, .day, .hour, .minute], from: midnight),
            DateComponents(year: 2026, month: 10, day: 17, hour: 0, minute: 0))
        XCTAssertEqual(WidgetSnapshot.refreshAfterMidnight(from: evening, calendar: utc), midnight.addingTimeInterval(60))
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
