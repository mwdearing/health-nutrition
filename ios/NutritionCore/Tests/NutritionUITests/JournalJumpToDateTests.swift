import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The instant every jump test loads at: 2023-11-14 22:13 UTC, so today's day key is 2023-11-14 in UTC.
private let jumpNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Noon UTC on a given day, so a picked day lands on that same day in every zone the tests use.
private func jumpDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utcInstant(year, month, day, 12)
}

/// A UTC instant on the given day and hour.
private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? jumpNow
}

/// The Journal's jump to a date, at view-model level: the section a picked day lands on, the sentence
/// for a day with nothing logged, and the empty journal. Synthetic entries only, a fixed locale and zone.
@MainActor
final class JournalJumpToDateTests: XCTestCase {
    private func makeJournalStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// Logs one synthetic food entry with a lowercase UUID id and returns that id.
    @discardableResult
    private func addEntry(_ store: JournalStore, at date: Date, zone: String = "UTC") throws -> String {
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: date, timeZoneIdentifier: zone, meal: nil),
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: Decimal(40), unit: .g)],
            product: nil, now: date)
        return id
    }

    private func makeModel(_ store: JournalStore) -> JournalViewModel {
        JournalViewModel(store: store, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
    }

    // MARK: Exact day

    /// A picked day that has entries lands on its own section and shows no sentence.
    func testExactDayIsFoundWithoutAMessage() throws {
        let journal = try makeJournalStore()
        let id = try addEntry(journal, at: jumpDay(2023, 11, 5))
        try addEntry(journal, at: jumpDay(2023, 11, 9))

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let target = model.jumpTarget(for: jumpDay(2023, 11, 5), now: jumpNow)
        XCTAssertEqual(target.sectionID, "2023-11-05")
        XCTAssertNil(target.message)
        XCTAssertEqual(model.sections.first { $0.id == target.sectionID }?.rows.map(\.id), [id])
    }

    // MARK: Day with nothing logged

    /// Nov 2 is three days before Nov 5 and Nov 9 is four days after, so the earlier day is the closest.
    /// The sentence names the picked day in the medium style.
    func testEmptyDayPicksTheCloserEarlierNeighbor() throws {
        let journal = try makeJournalStore()
        try addEntry(journal, at: jumpDay(2023, 11, 2))
        try addEntry(journal, at: jumpDay(2023, 11, 9))

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let target = model.jumpTarget(for: jumpDay(2023, 11, 5), now: jumpNow)
        XCTAssertEqual(target.sectionID, "2023-11-02")
        XCTAssertEqual(
            target.message, "Nothing logged on Nov 5, 2023. Showing the closest day with entries.")
    }

    /// Nov 1 is four days before Nov 5 and Nov 7 is two days after, so the later day is the closest.
    func testEmptyDayPicksTheCloserLaterNeighbor() throws {
        let journal = try makeJournalStore()
        try addEntry(journal, at: jumpDay(2023, 11, 1))
        try addEntry(journal, at: jumpDay(2023, 11, 7))

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let target = model.jumpTarget(for: jumpDay(2023, 11, 5), now: jumpNow)
        XCTAssertEqual(target.sectionID, "2023-11-07")
        XCTAssertEqual(
            target.message, "Nothing logged on Nov 5, 2023. Showing the closest day with entries.")
    }

    /// Nov 3 and Nov 7 are both two days from Nov 5, so the tie goes to the newer day.
    func testTieGoesToTheNewerDay() throws {
        let journal = try makeJournalStore()
        try addEntry(journal, at: jumpDay(2023, 11, 3))
        try addEntry(journal, at: jumpDay(2023, 11, 7))

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let target = model.jumpTarget(for: jumpDay(2023, 11, 5), now: jumpNow)
        XCTAssertEqual(target.sectionID, "2023-11-07")
        XCTAssertEqual(
            target.message, "Nothing logged on Nov 5, 2023. Showing the closest day with entries.")
    }

    // MARK: Future dates

    /// A date after today is treated as today. Today has entries, so the jump lands on today with no sentence.
    func testFutureDateMapsToTodayWhenTodayHasEntries() throws {
        let journal = try makeJournalStore()
        try addEntry(journal, at: jumpDay(2023, 11, 14))
        try addEntry(journal, at: jumpDay(2023, 11, 10))

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let target = model.jumpTarget(for: jumpDay(2023, 11, 20), now: jumpNow)
        XCTAssertEqual(target.sectionID, "2023-11-14")
        XCTAssertNil(target.message)
    }

    /// A future date with nothing logged today is treated as today: the closest day is Nov 10, and the
    /// sentence names today, Nov 14, not the date that was picked.
    func testFutureDateWithNothingTodayNamesTodayInTheSentence() throws {
        let journal = try makeJournalStore()
        try addEntry(journal, at: jumpDay(2023, 11, 10))

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let target = model.jumpTarget(for: jumpDay(2023, 11, 20), now: jumpNow)
        XCTAssertEqual(target.sectionID, "2023-11-10")
        XCTAssertEqual(
            target.message, "Nothing logged on Nov 14, 2023. Showing the closest day with entries.")
    }

    // MARK: Empty journal

    /// With no entries at all there is no section to go to, and the sentence says so.
    func testEmptyJournalGivesNoSectionAndNothingLoggedYet() throws {
        let journal = try makeJournalStore()

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let target = model.jumpTarget(for: jumpDay(2023, 11, 5), now: jumpNow)
        XCTAssertNil(target.sectionID)
        XCTAssertEqual(target.message, "Nothing logged yet.")
    }

    // MARK: Local day boundaries

    /// An entry at 10:00 on Nov 5 in Pacific/Kiritimati (UTC+14) is still Nov 4 in UTC. Its section is keyed
    /// by its own zone, so Nov 5 finds it exactly. Nov 4 finds no section of its own and falls to Nov 5.
    func testLocalDayBoundariesUseTheEntryZone() throws {
        let journal = try makeJournalStore()
        let id = try addEntry(journal, at: utcInstant(2023, 11, 4, 20), zone: "Pacific/Kiritimati")

        let model = makeModel(journal)
        model.load(now: jumpNow)

        let exact = model.jumpTarget(for: jumpDay(2023, 11, 5), now: jumpNow)
        XCTAssertEqual(exact.sectionID, "2023-11-05")
        XCTAssertNil(exact.message)
        XCTAssertEqual(model.sections.first { $0.id == exact.sectionID }?.rows.map(\.id), [id])

        let utcDay = model.jumpTarget(for: jumpDay(2023, 11, 4), now: jumpNow)
        XCTAssertEqual(utcDay.sectionID, "2023-11-05")
        XCTAssertEqual(
            utcDay.message, "Nothing logged on Nov 4, 2023. Showing the closest day with entries.")
    }

    /// A day more than a week back starts collapsed; jumping to it opens it, and a day already open stays open.
    func testRevealOpensACollapsedDayAndLeavesAnOpenDayOpen() throws {
        let journal = try makeJournalStore()
        try addEntry(journal, at: jumpDay(2023, 10, 20))
        try addEntry(journal, at: jumpDay(2023, 11, 14))
        let model = makeModel(journal)
        model.load(now: jumpNow)
        let old = try XCTUnwrap(model.sections.first { $0.id == "2023-10-20" })
        XCTAssertFalse(model.isExpanded(old), "an old day starts collapsed")

        model.reveal(model.jumpTarget(for: jumpDay(2023, 10, 20), now: jumpNow))
        XCTAssertTrue(model.isExpanded(old))
        model.reveal(model.jumpTarget(for: jumpDay(2023, 10, 20), now: jumpNow))
        XCTAssertTrue(model.isExpanded(old), "revealing an open day does not collapse it")
        model.reveal(JournalJumpTarget(sectionID: nil, message: "Nothing logged yet."))
    }
}
