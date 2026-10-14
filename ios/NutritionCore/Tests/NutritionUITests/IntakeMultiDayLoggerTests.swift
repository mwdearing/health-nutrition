import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A real journal whose creates fail after a set number, to show a failed write leaves no new entry.
private final class FailingCreatesJournal: JournalStore, @unchecked Sendable {
    struct Failure: Error {}
    let inner: SwiftDataJournalStore
    /// How many more creates succeed; nil never fails.
    var createsLeft: Int?
    var failDeletes = false

    init(_ inner: SwiftDataJournalStore) { self.inner = inner }

    var failNextSaveForTesting: Bool {
        get { inner.failNextSaveForTesting }
        set { inner.failNextSaveForTesting = newValue }
    }
    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        if let left = createsLeft {
            guard left > 0 else { throw Failure() }
            createsLeft = left - 1
        }
        return try inner.create(intake, components: components, product: product, now: now)
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        try inner.edit(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }
    func delete(intakeID: String, now: Date) throws {
        if failDeletes { throw Failure() }
        try inner.delete(intakeID: intakeID, now: now)
    }
    func activeIntakes() throws -> [Intake] { try inner.activeIntakes() }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { try inner.revisions(of: intakeID) }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? { try inner.product(snapshotID: snapshotID) }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }
}

/// Log on other days: one entry logged again on chosen past days, at the same time of day.
///
/// Synthetic names and ids only. Lowercase UUID intake ids.
@MainActor
final class IntakeMultiDayLoggerTests: XCTestCase {
    /// 2023-11-14 22:13:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    @discardableResult
    private func addEntry(
        _ store: JournalStore, at occurredAt: Date, zone: String = "UTC", product: ProductDefinition? = nil
    ) throws -> Intake {
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: occurredAt, timeZoneIdentifier: zone,
            meal: "breakfast")
        try store.create(
            intake, components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: product, now: occurredAt)
        return intake
    }

    func testLogsOnEachChosenDayAtTheSameTimeOfDayAndSkipsTheRest() throws {
        let journal = try makeJournal()
        let entry = try addEntry(journal, at: date("2023-11-10T08:15:00Z"))

        let result = try IntakeMultiDayLogger(store: journal).log(
            intakeID: entry.id, onDays: ["2023-11-10", "2023-11-12", "2023-11-14", "2023-11-15"], now: now)
        // The entry's own day and a day still to come are skipped, each with its reason.
        XCTAssertEqual(result.skipped, [
            MultiDaySkippedDay(day: "2023-11-10", reason: .entryDay), MultiDaySkippedDay(day: "2023-11-15", reason: .future),
        ])
        let copies = try journal.activeIntakes().filter { $0.id != entry.id }
        XCTAssertEqual(Set(copies.map(\.id)), Set(result.createdIDs))
        XCTAssertEqual(
            Set(copies.map(\.occurredAt)), [date("2023-11-12T08:15:00Z"), date("2023-11-14T08:15:00Z")])
        XCTAssertEqual(copies.map(\.meal), ["breakfast", "breakfast"])
        XCTAssertEqual(copies.map(\.timeZoneIdentifier), ["UTC", "UTC"])
        let amounts = try copies.flatMap { try journal.revisions(of: $0.id).flatMap(\.components).map(\.amount) }
        XCTAssertEqual(amounts, [40, 40])
        // The entry itself is untouched.
        XCTAssertEqual(try journal.revisions(of: entry.id).count, 1)
    }

    func testATimeOfDayStillToComeTodayIsSkipped() throws {
        let journal = try makeJournal()
        let entry = try addEntry(journal, at: date("2023-11-10T23:30:00Z"))

        let result = try IntakeMultiDayLogger(store: journal).log(intakeID: entry.id, onDays: ["2023-11-14"], now: now)
        XCTAssertEqual(result.createdIDs, [])
        XCTAssertEqual(result.skipped, [MultiDaySkippedDay(day: "2023-11-14", reason: .laterToday)])
    }

    func testTheTimeOfDayIsReadInTheEntrysOwnZone() throws {
        let journal = try makeJournal()
        // 07:00 in Tokyo is 22:00 UTC the day before.
        let entry = try addEntry(journal, at: date("2023-11-09T22:00:00Z"), zone: "Asia/Tokyo")

        _ = try IntakeMultiDayLogger(store: journal).log(intakeID: entry.id, onDays: ["2023-11-12"], now: now)
        let copy = try XCTUnwrap(journal.activeIntakes().first { $0.id != entry.id })
        XCTAssertEqual(copy.occurredAt, date("2023-11-11T22:00:00Z"))
        XCTAssertEqual(copy.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testADateThatDoesNotExistIsSkipped() throws {
        let journal = try makeJournal()
        let entry = try addEntry(journal, at: date("2023-11-10T08:15:00Z"))

        let result = try IntakeMultiDayLogger(store: journal).log(intakeID: entry.id, onDays: ["2023-02-31"], now: now)
        XCTAssertEqual(result.createdIDs, [])
        XCTAssertEqual(result.skipped, [MultiDaySkippedDay(day: "2023-02-31", reason: .notADate)])
    }

    func testRefusals() throws {
        let journal = try makeJournal()
        let entry = try addEntry(journal, at: date("2023-11-10T08:15:00Z"))
        let tooMany = Set((1...(IntakeMultiDayLogger.maximumDays + 1)).map { String(format: "2023-10-%02d", $0) })
        let cases: [(Set<String>, IntakeMultiDayError)] = [([], .invalidDays), (tooMany, .invalidDays), (["2023-11-1"], .invalidDays)]
        for (days, expected) in cases {
            XCTAssertThrowsError(try IntakeMultiDayLogger(store: journal).log(intakeID: entry.id, onDays: days, now: now)) {
                XCTAssertEqual($0 as? IntakeMultiDayError, expected)
            }
        }
        XCTAssertThrowsError(try IntakeMultiDayLogger(store: journal).log(intakeID: "missing", onDays: ["2023-11-12"], now: now)) {
            XCTAssertEqual($0 as? IntakeMultiDayError, .entryUnavailable)
        }
        let unzoned = try addEntry(journal, at: date("2023-11-10T08:15:00Z"), zone: "Not/AZone")
        XCTAssertThrowsError(try IntakeMultiDayLogger(store: journal).log(intakeID: unzoned.id, onDays: ["2023-11-12"], now: now)) {
            XCTAssertEqual($0 as? IntakeMultiDayError, .unreadableTimeZone)
        }
        XCTAssertEqual(try journal.activeIntakes().count, 2)
    }

    func testAFailedWriteLeavesNoNewEntry() throws {
        let inner = try makeJournal()
        let journal = FailingCreatesJournal(inner)
        let entry = try addEntry(journal, at: date("2023-11-10T08:15:00Z"))
        journal.createsLeft = 1

        XCTAssertThrowsError(try IntakeMultiDayLogger(store: journal).log(
            intakeID: entry.id, onDays: ["2023-11-11", "2023-11-12"], now: now)) {
            XCTAssertTrue($0 is FailingCreatesJournal.Failure)
        }
        XCTAssertEqual(try inner.activeIntakes().map(\.id), [entry.id])
    }

    func testAFailedCleanupNamesTheEntriesLeft() throws {
        let inner = try makeJournal()
        let journal = FailingCreatesJournal(inner)
        let entry = try addEntry(journal, at: date("2023-11-10T08:15:00Z"))
        journal.createsLeft = 1
        journal.failDeletes = true

        XCTAssertThrowsError(try IntakeMultiDayLogger(store: journal).log(
            intakeID: entry.id, onDays: ["2023-11-11", "2023-11-12"], now: now)) {
            let left = (try? inner.activeIntakes().map(\.id).filter { $0 != entry.id }) ?? []
            XCTAssertEqual($0 as? IntakeMultiDayError, .partial(remainingIDs: left))
            XCTAssertEqual(left.count, 1)
        }
    }

    func testTheEntryScreenSaysWhyNothingWasLogged() throws {
        let journal = try makeJournal()
        let entry = try addEntry(journal, at: date("2023-11-10T08:15:00Z"))
        let model = EntryDetailViewModel(store: journal, intakeID: entry.id)

        XCTAssertEqual(model.logOnDays(["2023-11-10"], now: now), .nothingLogged)
        XCTAssertEqual(model.multiDayMessage, "Nothing was logged: the days chosen are this entry's own day or still to come.")
        // The reason is the sheet's, not the entry screen's, so it does not stay on the entry after Cancel.
        XCTAssertNil(model.errorMessage)
        guard case .logged(let result) = model.logOnDays(["2023-11-12"], now: now) else { return XCTFail("nothing logged") }
        XCTAssertEqual(result.createdIDs.count, 1)
        XCTAssertNil(model.multiDayMessage)
    }

    func testTheSheetNamesEachSkippedDayWithItsReason() throws {
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        func text(_ created: Int, _ skipped: [(String, MultiDaySkipReason)], now: Date) -> String? {
            let result = IntakeMultiDayResult(
                createdIDs: (0..<created).map { "id-\($0)" },
                skipped: skipped.map { MultiDaySkippedDay(day: $0.0, reason: $0.1) })
            return LogOnOtherDaysSheet.loggedText(result, now: now, locale: locale, calendar: calendar)
        }

        XCTAssertNil(text(2, [], now: now))
        XCTAssertEqual(
            text(2, [("2023-11-10", .entryDay), ("2023-11-15", .future)], now: now),
            "Logged on 2 days. Skipped Nov 10 (this entry's day) and Nov 15 (in the future).")
        XCTAssertEqual(text(1, [("2023-11-10", .entryDay)], now: now), "Logged on 1 day. Skipped Nov 10 (this entry's day).")
        XCTAssertEqual(
            text(1, [("2023-11-10", .entryDay), ("2023-11-15", .future), ("2023-11-16", .future)], now: now),
            "Logged on 1 day. Skipped Nov 10 (this entry's day), Nov 15 (in the future), and Nov 16 (in the future).")
        XCTAssertEqual(text(1, [("2023-11-14", .laterToday)], now: now), "Logged on 1 day. Skipped Nov 14 (later today).")
        XCTAssertEqual(text(1, [("2023-02-31", .notADate)], now: now), "Logged on 1 day. Skipped 2023-02-31 (not a date).")
        // A day in another year carries its year.
        XCTAssertEqual(
            text(1, [("2023-12-31", .entryDay)], now: date("2024-01-02T09:00:00Z")),
            "Logged on 1 day. Skipped Dec 31, 2023 (this entry's day).")
    }

    func testPickedDatesBecomeGregorianDayKeys() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(
            IntakeMultiDayLogger.dayKey(DateComponents(calendar: gregorian, year: 2023, month: 3, day: 7)), "2023-03-07")
        XCTAssertNil(IntakeMultiDayLogger.dayKey(DateComponents(calendar: gregorian, year: 2023, month: 3)))
        // A picker showing the Japanese calendar states the era year (Reiwa 5 is 2023).
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = gregorian.timeZone
        let picked = japanese.dateComponents([.calendar, .timeZone, .era, .year, .month, .day], from: date("2023-03-07T12:00:00Z"))
        XCTAssertEqual(picked.year, 5)
        XCTAssertEqual(IntakeMultiDayLogger.dayKey(picked), "2023-03-07")
    }

    func testAFailedCleanupOnTheEntryScreenReportsTheEntriesLeft() throws {
        let inner = try makeJournal()
        let journal = FailingCreatesJournal(inner)
        let entry = try addEntry(journal, at: date("2023-11-10T08:15:00Z"))
        journal.createsLeft = 1
        journal.failDeletes = true
        let model = EntryDetailViewModel(store: journal, intakeID: entry.id)

        guard case .leftEntries(let left) = model.logOnDays(["2023-11-11", "2023-11-12"], now: now) else {
            return XCTFail("expected entries left")
        }
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(model.errorMessage, "Could not log on every day, and 1 new entry was left in the Journal. Delete it there.")
    }
}
