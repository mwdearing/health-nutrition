import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

final class IntakeCopierTests: XCTestCase {
    /// 2023-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)
    private var yesterday: Date { now.addingTimeInterval(-86_400) }
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    @discardableResult
    private func add(
        _ store: JournalStore, name: String, at date: Date, meal: String? = nil, zone: String = "UTC",
        amount: Decimal = 40, snapshot: ProductDefinition? = nil
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let intake = Intake(id: id, category: "food", occurredAt: date, timeZoneIdentifier: zone, meal: meal)
        try store.create(
            intake,
            components: [IntakeComponent(componentID: name.lowercased(), name: name, amount: amount, unit: .g)],
            product: snapshot, now: date)
        return id
    }

    private func copier(_ store: JournalStore) -> IntakeCopier {
        IntakeCopier(store: store, timeZoneIdentifier: "UTC")
    }

    func testYesterdayKeyIsThePreviousLocalDay() throws {
        XCTAssertEqual(copier(try makeStore()).yesterdayKey(now: now), "2023-11-14")
    }

    func testCopyYesterdayCopiesOnlyYesterdayToNowAndLeavesSources() throws {
        let store = try makeStore()
        let a = try add(store, name: "Oats", at: yesterday, meal: "breakfast", amount: Decimal(string: "37.5")!)
        let b = try add(store, name: "Rice", at: yesterday.addingTimeInterval(3600), meal: "lunch")
        let older = try add(store, name: "Old", at: yesterday.addingTimeInterval(-86_400))
        let result = try copier(store).copyYesterday(now: now)
        XCTAssertEqual(result.copiedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)
        let all = try store.activeIntakes()
        XCTAssertEqual(all.count, 5)
        let created = all.filter { result.createdIDs.contains($0.id) }
        XCTAssertEqual(Set(created.map(\.occurredAt)), [now])
        XCTAssertEqual(Set(created.compactMap(\.meal)), ["breakfast", "lunch"])
        let oatsCopy = try XCTUnwrap(created.first { $0.meal == "breakfast" })
        let revision = try XCTUnwrap(store.revisions(of: oatsCopy.id).first)
        XCTAssertEqual(revision.components.first?.amount, Decimal(string: "37.5"))
        XCTAssertFalse(result.createdIDs.contains(a))
        XCTAssertFalse(result.createdIDs.contains(b))
        XCTAssertFalse(result.createdIDs.contains(older))
        XCTAssertEqual(try store.revisions(of: a).count, 1)
    }

    func testCopyMealCopiesOnlyThatMeal() throws {
        let store = try makeStore()
        try add(store, name: "Oats", at: yesterday, meal: "breakfast")
        try add(store, name: "Egg", at: yesterday, meal: "Breakfast ")
        try add(store, name: "Rice", at: yesterday, meal: "lunch")
        let result = try copier(store).copyMeal(.named(.breakfast), dayKey: "2023-11-14", now: now)
        XCTAssertEqual(result.copiedCount, 2)
        XCTAssertEqual(try store.activeIntakes().count, 5)
    }

    func testOtherMealCoversNoMealAndUnnamedMeal() throws {
        let store = try makeStore()
        try add(store, name: "Plain", at: yesterday)
        try add(store, name: "Free", at: yesterday, meal: "brunch")
        try add(store, name: "Lunch", at: yesterday, meal: "lunch")
        let result = try copier(store).copyMeal(.other, dayKey: "2023-11-14", now: now)
        XCTAssertEqual(result.copiedCount, 2)
    }

    func testDeletedEntriesAreNotCopiedAndEmptyDayCopiesNothing() throws {
        let store = try makeStore()
        let gone = try add(store, name: "Gone", at: yesterday)
        try store.delete(intakeID: gone, now: now)
        let result = try copier(store).copyYesterday(now: now)
        XCTAssertEqual(result, IntakeCopyResult(createdIDs: [], skippedCount: 0))
        XCTAssertEqual(try store.activeIntakes().count, 0)
    }

    func testDayIsReadInTheEntrysOwnZone() throws {
        let store = try makeStore()
        // 2023-11-14 23:00 UTC is already 2023-11-15 in Auckland.
        let late = Date(timeIntervalSince1970: 1_699_999_200)
        let id = try add(store, name: "Late", at: late, zone: "Pacific/Auckland")
        XCTAssertEqual(try copier(store).sources(dayKey: "2023-11-15").map(\.id), [id])
        XCTAssertEqual(try copier(store).sources(dayKey: "2023-11-14").map(\.id), [])
    }

    func testEntryWithUnavailableProductIsSkippedAndCounted() throws {
        let store = try makeStore()
        let snapshot = ProductDefinition(
            snapshotID: "snap-1", productID: "p-1", name: "Bar", labelBasis: "per_serving",
            catalogOrigin: "test", catalogVersion: "1")
        try add(store, name: "Bar", at: yesterday, snapshot: snapshot)
        try add(store, name: "Plain", at: yesterday)
        let result = try copier(store).copyYesterday(now: now)
        XCTAssertEqual(result.copiedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)
    }

    func testEntryWithInvalidZoneIsNeverCopied() throws {
        let store = try makeStore()
        try add(store, name: "Odd", at: yesterday, zone: "Not/AZone")
        XCTAssertEqual(try copier(store).sources(dayKey: "2023-11-14").count, 0)
        let result = try copier(store).copyYesterday(now: now)
        XCTAssertEqual(result.copiedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testStoreFailureStopsAndReportsWhatWasWritten() throws {
        let store = try makeStore()
        try add(store, name: "A", at: yesterday)
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try copier(store).copyYesterday(now: now)) { error in
            guard case IntakeCopyError.stoppedEarly(let partial, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(partial.copiedCount, 0)
        }
    }
}
