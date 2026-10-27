import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A time-zone change while the Diary is open reloads it, so the days follow the new zone (#648).
@MainActor
final class ZoneChangeReloadTests: XCTestCase {
    /// 02:00 UTC on 2026-10-20: the 19th in New York, the 20th in Tokyo.
    private let now = Date(timeIntervalSince1970: 1_792_461_600)

    /// The zone the test changes by hand, as the device would.
    private final class ZoneBox { var identifier = "America/New_York" }

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testZoneChangeReloadsTheDiaryInTheNewZone() async throws {
        let store = try makeStore()
        let zone = ZoneBox()
        let add = AddIntakeViewModel(store: store, now: now, timeZoneProvider: { zone.identifier })
        add.name = "Oats"
        add.amountText = "40"
        XCTAssertTrue(add.save(now: now))
        let journal = JournalViewModel(store: store, timeZoneProvider: { zone.identifier })
        journal.load(now: now)
        XCTAssertEqual(journal.sections.first?.id, "2026-10-19", "New York files the entry on the 19th")

        zone.identifier = "Asia/Tokyo"
        let loadsBefore = journal.loadCount
        let changes = AsyncStream<Void> { continuation in
            continuation.yield(())
            continuation.finish()
        }
        await journal.runZoneChangeReloads({ changes }, now: { self.now })
        // One reload when the subscription starts (#655), one for the change.
        XCTAssertEqual(journal.loadCount, loadsBefore + 2, "the subscription and the zone change each reload the Diary")
        XCTAssertEqual(journal.dayZone.identifier, "Asia/Tokyo", "the Diary now reads days in the new zone")
        // Today is Tokyo's date now, and empty, so it is the today section; the New York entry stays on its own day.
        XCTAssertEqual(journal.todaySection?.id, "2026-10-20", "after the change today is Tokyo's date")
        XCTAssertEqual(journal.arrowSectionIDs.first, "2026-10-20", "the arrows start from Tokyo's today")
        XCTAssertEqual(journal.sections.first?.id, "2026-10-19", "an entry keeps the day of the zone it was saved in")
    }

    /// #655: a zone change made after the subscription is created but before its first element is applied.
    func testAZoneChangeInTheSubscriptionGapIsApplied() async throws {
        let store = try makeStore()
        let zone = ZoneBox()
        let add = AddIntakeViewModel(store: store, now: now, timeZoneProvider: { zone.identifier })
        add.name = "Oats"
        add.amountText = "40"
        XCTAssertTrue(add.save(now: now))
        let journal = JournalViewModel(store: store, timeZoneProvider: { zone.identifier })
        journal.load(now: now)
        XCTAssertEqual(journal.dayZone.identifier, "America/New_York")

        // The change lands while the subscription is being made, before anything is delivered.
        let gap = AsyncStream<Void> { continuation in
            zone.identifier = "Asia/Tokyo"
            continuation.finish()
        }
        await journal.runZoneChangeReloads({ gap }, now: { self.now })
        XCTAssertEqual(journal.dayZone.identifier, "Asia/Tokyo", "a change made before the subscription is applied")
        XCTAssertEqual(journal.todaySection?.id, "2026-10-20", "today follows Tokyo after the gap change")
    }

    private final class StartCounter { var count = 0 }

    /// #654: a stream that throws is started again, so a later zone change still reloads the Diary.
    func testAFailedZoneChangeStreamIsStartedAgain() async throws {
        let store = try makeStore()
        let zone = ZoneBox()
        let journal = JournalViewModel(store: store, timeZoneProvider: { zone.identifier })
        journal.load(now: now)
        let starts = StartCounter()
        let loadsBefore = journal.loadCount
        zone.identifier = "Asia/Tokyo"
        await journal.runZoneChangeReloads({ () -> AsyncThrowingStream<Void, Error> in
            starts.count += 1
            if starts.count == 1 {
                return AsyncThrowingStream<Void, Error> { $0.finish(throwing: ZoneStreamFailure.failed) }
            }
            return AsyncThrowingStream<Void, Error> { continuation in
                continuation.yield(())
                continuation.finish()
            }
        }, now: { self.now })
        XCTAssertEqual(starts.count, 2, "the failed stream is started again")
        XCTAssertEqual(journal.loadCount, loadsBefore + 3, "the first start, the restart and the change each reload")
        XCTAssertEqual(journal.dayZone.identifier, "Asia/Tokyo")
    }

    private enum ZoneStreamFailure: Error { case failed }
}
