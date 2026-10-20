import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The add flow stamps the zone at save, and the Diary files the row under the same zone (#539).
@MainActor
final class DiaryZoneRuleTests: XCTestCase {
    /// 02:00 UTC on 2026-10-20: 22:00 on the 19th in New York (EDT), 11:00 on the 20th in Tokyo.
    private let now = Date(timeIntervalSince1970: 1_792_461_600)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// Switching the zone between opening the add form and saving must stamp the zone at save time.
    func testSaveStampsTheZoneCurrentAtSaveAndTheDiaryFilesItUnderThatDay() throws {
        let store = try makeStore()
        var zone = "America/New_York"
        let add = AddIntakeViewModel(store: store, now: now, timeZoneProvider: { zone })
        add.name = "Oats"
        add.amountText = "40"
        zone = "Asia/Tokyo"
        XCTAssertTrue(add.save(now: now))

        let saved = try XCTUnwrap(store.activeIntakes().first)
        XCTAssertEqual(saved.timeZoneIdentifier, "Asia/Tokyo")

        let journal = JournalViewModel(store: store, timeZoneProvider: { zone })
        journal.load(now: now)
        XCTAssertEqual(journal.sections.first?.id, "2026-10-20")
        XCTAssertEqual(journal.arrowSectionIDs.first, "2026-10-20")
    }

    /// With no zone given, the add flow stamps the same zone the Diary groups by, at the call site (#539).
    func testDefaultZonesAgreeAtTheCallSite() throws {
        let store = try makeStore()
        let add = AddIntakeViewModel(store: store, now: now)
        add.name = "Oats"
        add.amountText = "40"
        XCTAssertTrue(add.save(now: now))
        let saved = try XCTUnwrap(store.activeIntakes().first)
        XCTAssertEqual(saved.timeZoneIdentifier, TimeZone.current.identifier)
        let journal = JournalViewModel(store: store)
        XCTAssertEqual(journal.dayZone.identifier, saved.timeZoneIdentifier)
    }

    /// The Diary's arrows start from today's day even when today is empty, the same list the Diary shows (#539).
    func testArrowSectionsIncludeAnEmptyToday() throws {
        let store = try makeStore()
        let yesterday = now.addingTimeInterval(-86_400)
        let seed = AddIntakeViewModel(store: store, now: yesterday, timeZoneIdentifier: "UTC")
        seed.name = "Oats"
        seed.amountText = "40"
        XCTAssertTrue(seed.save(now: yesterday))
        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        journal.load(now: now)
        XCTAssertEqual(journal.arrowSectionIDs.first, "2026-10-20")
        // With today as the only visible day, the arrows start from today's midnight, not yesterday's.
        let base = JournalViewModel.arrowBaseDay(
            sectionIDs: journal.arrowSectionIDs, visible: ["2026-10-20"], zone: journal.dayZone, now: now)
        XCTAssertEqual(JournalViewModel.dayKey(base, zone: journal.dayZone), "2026-10-20")
    }

    /// The arrow ids follow the sections when a day's last entry is deleted and the Diary reloads (#611).
    func testArrowIdsFollowADeletedDay() throws {
        let store = try makeStore()
        let yesterday = now.addingTimeInterval(-86_400)
        let seed = AddIntakeViewModel(store: store, now: yesterday, timeZoneIdentifier: "UTC")
        seed.name = "Oats"
        seed.amountText = "40"
        XCTAssertTrue(seed.save(now: yesterday))
        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        journal.load(now: now)
        XCTAssertTrue(journal.arrowSectionIDs.contains("2026-10-19"))
        try store.delete(intakeID: try XCTUnwrap(store.activeIntakes().first).id, now: now)
        journal.load(now: now)
        XCTAssertEqual(journal.arrowSectionIDs, journal.diarySections.map(\.id))
        XCTAssertFalse(journal.arrowSectionIDs.contains("2026-10-19"))
    }
}
