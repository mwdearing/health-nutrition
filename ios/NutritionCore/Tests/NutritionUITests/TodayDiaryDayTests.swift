import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// #1139 (Mike's pick A, 2026-10-31): Today counts the entries whose own-zone day is the Diary's today, today's date
/// in the current zone, so after travel both screens show the same entries.
@MainActor
final class TodayDiaryDayTests: XCTestCase {
    // 2023-11-14 22:13 UTC, which is 2023-11-15 07:13 in Tokyo.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func logWater(_ store: SwiftDataJournalStore, at date: Date, zone: String, amount: Decimal) throws {
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: date, timeZoneIdentifier: zone),
            components: [IntakeComponent(componentID: "water", name: "Example water", amount: amount, unit: .mL)],
            product: nil, now: now)
    }

    private func diaryTodayRowCount(_ store: SwiftDataJournalStore, zone: String) -> Int {
        let diary = JournalViewModel(store: store, timeZoneIdentifier: zone, locale: Locale(identifier: "en_US"))
        diary.load(now: now)
        let key = JournalViewModel.dayKey(now, zone: TimeZone(identifier: zone)!)
        return diary.sections.first { $0.id == key }?.rows.count ?? 0
    }

    /// The issue's case: back home in UTC, an entry logged at this instant in Tokyo is on 2023-11-15 there. The
    /// Diary files it under tomorrow, so Today leaves it out too.
    func testAnEntryWhoseOwnDayIsTomorrowIsNotOnToday() throws {
        let store = try makeStore()
        try logWater(store, at: now, zone: "Asia/Tokyo", amount: 250)

        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        XCTAssertEqual(today.waterTotalMilliliters, 0)
        XCTAssertEqual(today.waterEntryCount, 0)
        XCTAssertEqual(diaryTodayRowCount(store, zone: "UTC"), 0)
    }

    /// Now in Tokyo: the same entry is on 2023-11-15, which is today there, on both screens; one logged in UTC this
    /// morning keeps its own day, 2023-11-14, which is yesterday in Tokyo.
    func testTodayAndTheDiarysTodayHoldTheSameEntries() throws {
        let store = try makeStore()
        try logWater(store, at: now, zone: "Asia/Tokyo", amount: 250)
        try logWater(store, at: now.addingTimeInterval(-3_600), zone: "UTC", amount: 100)

        let today = TodayViewModel(store: store, timeZoneIdentifier: "Asia/Tokyo")
        today.load(now: now)
        XCTAssertEqual(today.waterTotalMilliliters, 250)
        XCTAssertEqual(today.waterEntryCount, 1)
        XCTAssertEqual(diaryTodayRowCount(store, zone: "Asia/Tokyo"), 1)

        let home = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        home.load(now: now)
        XCTAssertEqual(home.waterTotalMilliliters, 100)
        XCTAssertEqual(diaryTodayRowCount(store, zone: "UTC"), 1)
    }

    /// The entry keeps its own local time on Today, whichever zone decides the day.
    func testAnEntryKeepsItsOwnLocalTime() throws {
        let store = try makeStore()
        // 2023-11-14 08:13 in Los Angeles, which is 2023-11-14 in UTC too.
        try store.create(
            Intake(
                id: "la", category: "food", occurredAt: now.addingTimeInterval(-6 * 3_600),
                timeZoneIdentifier: "America/Los_Angeles"),
            components: [IntakeComponent(componentID: "c", name: "Example toast", amount: 30, unit: .g)],
            product: nil, now: now)
        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        let row = try XCTUnwrap(today.rows.first)
        XCTAssertEqual(row.timeText, TodayViewModel.timeText(row.occurredAt, zoneIdentifier: "America/Los_Angeles"))
    }
}
