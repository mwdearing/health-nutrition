import NutritionUI
import XCTest

@testable import HealthNutrition

@MainActor
private final class FakeStack: SupplementTakenLogging {
    var items: [ShortcutSupplement]
    var refusalMessage: String?
    var result = true
    private(set) var loads = 0
    private(set) var taken: [(id: String, time: ReminderTime?)] = []

    init(items: [ShortcutSupplement]) { self.items = items }

    func load(now: Date) { loads += 1 }

    func markTaken(id: String, at time: ReminderTime?, now: Date) -> Bool {
        taken.append((id, time))
        return result
    }
}

@MainActor
final class LogSupplementShortcutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let evening = ReminderTime(hour: 20, minute: 0)

    func testLogsTheItemAtItsOpenTimeThroughTheListsOwnCall() {
        let stack = FakeStack(items: [ShortcutSupplement(id: "a", title: "Creatine", openTimes: [evening])])
        let outcome = SupplementShortcut.log(favoriteID: "a", now: now, stack: stack)
        XCTAssertEqual(outcome, .init(logged: true, message: "Logged Creatine"))
        XCTAssertEqual(stack.taken.count, 1)
        XCTAssertEqual(stack.taken[0].id, "a")
        XCTAssertEqual(stack.taken[0].time, evening)
        XCTAssertEqual(stack.loads, 1)
    }

    func testWithNoOpenTimeItMarksNoTime() {
        let stack = FakeStack(items: [ShortcutSupplement(id: "a", title: "Creatine", openTimes: [])])
        _ = SupplementShortcut.log(favoriteID: "a", now: now, stack: stack)
        XCTAssertEqual(stack.taken.count, 1)
        XCTAssertNil(stack.taken[0].time)
    }

    func testAnEmptyListAnUnknownItemAndMissingServicesWriteNothing() {
        let empty = FakeStack(items: [])
        XCTAssertEqual(
            SupplementShortcut.log(favoriteID: "a", now: now, stack: empty).message, SupplementShortcut.emptyListMessage)
        let other = FakeStack(items: [ShortcutSupplement(id: "b", title: "Zinc", openTimes: [])])
        XCTAssertEqual(
            SupplementShortcut.log(favoriteID: "a", now: now, stack: other).message, SupplementShortcut.notOnListMessage)
        XCTAssertEqual(
            SupplementShortcut.log(favoriteID: "a", now: now, stack: nil).message, SupplementShortcut.notReadyMessage)
        XCTAssertTrue(empty.taken.isEmpty && other.taken.isEmpty)
    }

    func testARefusalSaysTheListsOwnReasonAndIsNotReportedAsLogged() {
        let stack = FakeStack(items: [ShortcutSupplement(id: "a", title: "Creatine", openTimes: [])])
        stack.result = false
        stack.refusalMessage = "This item has no amounts to log."
        let outcome = SupplementShortcut.log(favoriteID: "a", now: now, stack: stack)
        XCTAssertEqual(outcome, .init(logged: false, message: "This item has no amounts to log."))
    }

    func testARefusalWithNoReasonFallsBackToTheGenericMessage() {
        let stack = FakeStack(items: [ShortcutSupplement(id: "a", title: "Creatine", openTimes: [])])
        stack.result = false
        XCTAssertEqual(
            SupplementShortcut.log(favoriteID: "a", now: now, stack: stack).message, SupplementShortcut.failedMessage)
    }

    func testNothingIsWrittenWhileAnEraseRuns() {
        let stack = FakeStack(items: [ShortcutSupplement(id: "a", title: "Creatine", openTimes: [])])
        let outcome = SupplementShortcut.log(favoriteID: "a", now: now, stack: stack, isErasing: true)
        XCTAssertEqual(outcome, .init(logged: false, message: SupplementShortcut.failedMessage))
        XCTAssertTrue(stack.taken.isEmpty)
    }

    func testAnEmptyListThatCouldNotBeReadSaysWhyNotToAddOne() {
        let stack = FakeStack(items: [])
        stack.refusalMessage = "Could not read your supplements."
        let outcome = SupplementShortcut.log(favoriteID: "a", now: now, stack: stack)
        XCTAssertEqual(outcome, .init(logged: false, message: "Could not read your supplements."))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: hour, minute: minute))!
    }

    private let morning = ReminderTime(hour: 8, minute: 0)

    func testNineInTheEveningMarksEightInTheEvening() {
        XCTAssertEqual(
            SupplementShortcut.nearestOpenTime(in: [morning, evening], to: date(hour: 21), calendar: utc), evening)
    }

    func testElevenInTheMorningMarksEightInTheMorning() {
        XCTAssertEqual(
            SupplementShortcut.nearestOpenTime(in: [morning, evening], to: date(hour: 11), calendar: utc), morning)
    }

    func testATieGoesToTheEarlierTimeAndAnEmptyListToNil() {
        XCTAssertEqual(
            SupplementShortcut.nearestOpenTime(in: [evening, morning], to: date(hour: 14), calendar: utc), morning)
        XCTAssertNil(SupplementShortcut.nearestOpenTime(in: [], to: date(hour: 14), calendar: utc))
    }

    func testTheShortcutLogsTheNearestOpenTimeNotTheEarliest() {
        let stack = FakeStack(items: [ShortcutSupplement(id: "a", title: "Creatine", openTimes: [morning, evening])])
        _ = SupplementShortcut.log(favoriteID: "a", now: date(hour: 21), stack: stack, calendar: utc)
        XCTAssertEqual(stack.taken.first?.time, evening)
    }
}
