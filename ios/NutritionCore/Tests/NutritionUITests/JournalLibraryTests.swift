import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Forwards to a real store and counts the write calls.
private final class CountingStore: JournalStore, @unchecked Sendable {
    let inner: SwiftDataJournalStore
    var createCalls = 0
    var editCalls = 0
    var deleteCalls = 0
    var lastEditProductSnapshotID: String?
    /// What the last `edit` was asked to correct the entry's time to, and the zone it named with
    /// it. Nil for an edit that was not given a time, which is the amounts-only case.
    var lastEditOccurredAt: Date?
    var lastEditTimeZoneIdentifier: String?

    init(inner: SwiftDataJournalStore) { self.inner = inner }

    var failNextSaveForTesting: Bool {
        get { inner.failNextSaveForTesting }
        set { inner.failNextSaveForTesting = newValue }
    }

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        createCalls += 1
        return try inner.create(intake, components: components, product: product, now: now)
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        editCalls += 1
        lastEditProductSnapshotID = product?.snapshotID
        lastEditOccurredAt = occurredAt
        lastEditTimeZoneIdentifier = timeZoneIdentifier
        return try inner.edit(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason,
            now: now, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }
    func delete(intakeID: String, now: Date) throws {
        deleteCalls += 1
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

/// Serves canned records so tests can hold stored values the real store would refuse to create.
///
/// An `edit` is recorded and applied rather than refused, so a test can also hold a stored value the real
/// store cannot write — a missing amount is one — and then save over it. `SwiftDataJournalStore` cannot be
/// used for that: it refuses a not-a-number amount outright, so such a row can only reach a screen through a
/// store that already has it. Tests that only read are unaffected: they never call `edit`.
private final class CannedStore: JournalStore, @unchecked Sendable {
    var failNextSaveForTesting = false
    var intakes: [Intake]
    var components: [String: [IntakeComponent]]
    var changeReason = "test"
    var editCalls = 0
    /// What the last `edit` was asked to write, which is the only way a test reads back what a save carried.
    var lastEditedComponents: [IntakeComponent]?

    init(intakes: [Intake], components: [String: [IntakeComponent]]) {
        self.intakes = intakes
        self.components = components
    }

    private struct Unsupported: Error {}

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision { throw Unsupported() }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        editCalls += 1
        lastEditedComponents = components
        self.changeReason = changeReason
        self.components[intakeID] = components
        if let occurredAt, let index = intakes.firstIndex(where: { $0.id == intakeID }) {
            intakes[index].occurredAt = occurredAt
        }
        return IntakeRevision(
            intakeID: intakeID, number: 1, components: components, productSnapshotID: nil,
            changeReason: changeReason, createdAt: Date(timeIntervalSince1970: 0),
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }
    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { intakes }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        guard let list = components[intakeID] else { throw Unsupported() }
        return [IntakeRevision(
            intakeID: intakeID, number: 1, components: list, productSnapshotID: nil,
            changeReason: changeReason, createdAt: Date(timeIntervalSince1970: 0))]
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { nil }
    func activeIntakesFromBackground() async throws -> [Intake] { intakes }
    func close() {}
}

@MainActor
final class JournalLibraryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore() throws -> CountingStore {
        let directory = try makeDirectory()
        return CountingStore(inner: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")))
    }

    @discardableResult
    private func addFood(
        _ store: JournalStore, name: String = "Oats", at date: Date, zone: String = "UTC", amount: Decimal = 40,
        category: String = "food", product: ProductDefinition? = nil, meal: String? = nil
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let intake = Intake(
            id: id, category: category, occurredAt: date, timeZoneIdentifier: zone, meal: meal)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        try store.create(
            intake, components: [IntakeComponent(componentID: slug, name: name, amount: amount, unit: .g)],
            product: product, now: date)
        return id
    }

    private func product(_ snapshot: String) -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshot, productID: "p-\(snapshot)", name: "Test bar", labelBasis: "per_serving",
            catalogOrigin: "test", catalogVersion: "1")
    }

    func testPickModeRowLabelDoesNotSayAdd() {
        let template = RepeatTemplate(displayName: "Oats", category: "food",
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)])
        for kind in [ProductKind.food, .supplement] {
            let item = LibraryItem(id: "oats", title: "Oats", detail: "40 g",
                isFavorite: false, template: template, kind: kind)
            let label = item.accessibilityLabel(forPick: true)
            XCTAssertFalse(label.hasPrefix("Add"))
            XCTAssertTrue(label.contains("Oats"))
            XCTAssertTrue(label.contains("opens details"))
            XCTAssertTrue(item.accessibilityLabel(forPick: false).hasPrefix("Add Oats"))
        }
    }

    // MARK: Journal

    func testJournalGroupsByLocalDayOfEachIntakesOwnZoneNewestFirst() throws {
        let store = try makeStore()
        let a = try addFood(store, name: "A", at: now)
        let b = try addFood(store, name: "B", at: now, zone: "Pacific/Auckland")
        let c = try addFood(store, name: "C", at: now.addingTimeInterval(3600))
        let model = JournalViewModel(store: store)
        model.load(now: now)
        XCTAssertEqual(model.sections.map(\.id), ["2023-11-15", "2023-11-14"])
        XCTAssertEqual(model.sections[0].rows.map(\.id), [b])
        XCTAssertEqual(model.sections[1].rows.map(\.id), [c, a])
    }

    func testJournalInvalidTimeZoneAndUnreadableRecordAreSkippedAndCounted() throws {
        let good = Intake(id: "a", category: "food", occurredAt: now, timeZoneIdentifier: "UTC")
        let badZone = Intake(id: "b", category: "food", occurredAt: now, timeZoneIdentifier: "Not/AZone")
        let unreadable = Intake(id: "c", category: "food", occurredAt: now, timeZoneIdentifier: "UTC")
        let item = IntakeComponent(componentID: "x", name: "X", amount: 1, unit: .g)
        let store = CannedStore(intakes: [good, badZone, unreadable], components: ["a": [item], "b": [item]])
        let model = JournalViewModel(store: store)
        model.load(now: now)
        XCTAssertEqual(model.sections.flatMap(\.rows).map(\.id), ["a"])
        XCTAssertEqual(model.skippedCount, 2)
    }

    func testJournalDeletedHiddenAfterDelete() throws {
        let store = try makeStore()
        let keep = try addFood(store, name: "Keep", at: now)
        let gone = try addFood(store, name: "Gone", at: now.addingTimeInterval(60))
        try store.delete(intakeID: gone, now: now)
        let model = JournalViewModel(store: store)
        model.load(now: now)
        XCTAssertEqual(model.sections.flatMap(\.rows).map(\.id), [keep])
    }

    func testJournalUnknownNotZeroForMissingAmount() throws {
        let intake = Intake(id: "a", category: "food", occurredAt: now, timeZoneIdentifier: "UTC")
        let unknownAmount = IntakeComponent(componentID: "x", name: "X", amount: Decimal.nan, unit: .g)
        let store = CannedStore(intakes: [intake], components: ["a": [unknownAmount]])
        let model = JournalViewModel(store: store)
        model.load(now: now)
        XCTAssertEqual(model.sections.first?.rows.first?.detail, "unknown")
        let detail = EntryDetailViewModel(store: store, intakeID: "a")
        detail.load(now: now)
        XCTAssertEqual(detail.components.first?.amountText, "unknown")
    }

    func testDayHeaderTitleUsesFixedLocaleAndIntakeZone() throws {
        let store = try makeStore()
        let date = Date(timeIntervalSince1970: 1_705_361_400)
        _ = try addFood(store, name: "Oats", at: date, amount: 1, product: product("snap-t"))
        let model = JournalViewModel(store: store, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        model.load(now: date)
        XCTAssertEqual(model.sections.first?.id, "2024-01-15")
        XCTAssertEqual(model.sections.first?.title, "Jan 15, 2024")
    }

    func testRepeatCreatesNewIntakeWithCopiedComponentsAndLeavesOriginal() throws {
        let store = try makeStore()
        let snapshot = product("snap-1")
        let original = try addFood(store, name: "Oats", at: now.addingTimeInterval(-86_400), amount: Decimal(string: "37.5")!, product: snapshot)
        let model = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        let newID = model.repeatIntake(original, now: now)
        XCTAssertEqual(store.createCalls, 2)
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.count, 2)
        let created = try XCTUnwrap(intakes.first { $0.id == newID })
        XCTAssertNotEqual(newID, original)
        XCTAssertTrue(JournalValidation.isValidIntakeID(created.id))
        XCTAssertEqual(created.occurredAt, now)
        let copy = try store.revisions(of: created.id)
        XCTAssertEqual(copy.first?.components.first?.amount, Decimal(string: "37.5"))
        XCTAssertEqual(copy.first?.productSnapshotID, "snap-1")
        let untouched = try store.revisions(of: original)
        XCTAssertEqual(untouched.count, 1)
        XCTAssertEqual(try store.activeIntakes().first { $0.id == original }?.currentRevision, 1)
    }

    // MARK: Entry detail

    func testEntryDetailRevisionHistoryAndDestinationStateAsText() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        XCTAssertTrue(model.save(components: [EditedComponent(componentID: "oats", name: "Oats", amountText: "50", unit: .g)], changeReason: "More", now: now))
        XCTAssertEqual(model.revisions.map(\.number), [2, 1])
        XCTAssertEqual(model.revisions.first?.changeReason, "More")
        XCTAssertEqual(Set(model.destinations.map(\.destination)), [.healthKit, .relay])
        XCTAssertTrue(model.destinations.allSatisfy { !$0.stateText.isEmpty && !$0.iconName.isEmpty })
        XCTAssertEqual(model.destinations.first?.stateText, "Pending")
    }

    func testDestinationStateTextCoversEveryState() {
        let texts = DestinationState.allCases.map { EntryDetailViewModel.stateText($0) }
        XCTAssertEqual(Set(texts).count, DestinationState.allCases.count)
        XCTAssertEqual(Set(DestinationState.allCases.map { EntryDetailViewModel.icon($0) }).count, DestinationState.allCases.count)
    }

    func testEditCreatesRevisionWithOneEditCall() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.drafts["oats"] = "42.25"
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(store.editCalls, 1)
        XCTAssertEqual(model.currentRevision, 2)
        let revisions = try store.revisions(of: id)
        XCTAssertEqual(revisions.map(\.number), [1, 2])
        XCTAssertEqual(revisions.last?.components.first?.amount, Decimal(string: "42.25"))
    }

    /// A person who logged dinner at 23:00 that they ate at 19:00 yesterday corrects it from the
    /// entry screen. That is one `edit` call: the new revision carries the corrected instant, the
    /// previous revision is kept, and the projections the correction supersedes are not updated.
    func testEntryDetailCorrectsOccurredAtInOneEditCall() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let corrected = now.addingTimeInterval(-86_400)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        XCTAssertEqual(model.occurredAt, now, "load seeds the draft from the stored time")
        model.occurredAt = corrected
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(store.editCalls, 1)
        XCTAssertEqual(store.lastEditOccurredAt, corrected)
        XCTAssertEqual(store.lastEditTimeZoneIdentifier, "UTC")
        XCTAssertEqual(try store.activeIntakes().first { $0.id == id }?.occurredAt, corrected)
        XCTAssertEqual(try store.revisions(of: id).map(\.number), [1, 2])
        XCTAssertEqual(
            try store.projections(of: id).filter { $0.revision == 1 }.map(\.isCurrent), [false, false])
        XCTAssertEqual(model.occurredAt, corrected, "the draft follows the entry after the save")
    }

    /// A time-only correction is recorded as one, because a history that says "Edited" for a
    /// change of time tells the reader nothing about what happened.
    func testEntryDetailRecordsATimeOnlyCorrectionAsItsOwnReason() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(model.revisions.first?.changeReason, "Time corrected")
        // A reason the person wrote is kept whatever it says.
        model.changeReason = "eaten earlier"
        model.occurredAt = now.addingTimeInterval(-7_200)
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(model.revisions.first?.changeReason, "eaten earlier")
    }

    /// A save that moves the amounts **and** the time is an ordinary edit, and is recorded as one. Labelling
    /// it "Time corrected" would tell a reader the time was the only thing that changed when the amounts
    /// changed too, and the history would then misdescribe the correction.
    func testEntryDetailRecordsATimeAndAmountChangeAsAnOrdinaryEdit() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now, amount: 40)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.drafts["oats"] = "55"
        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.saveDrafts(now: now))

        XCTAssertEqual(
            model.revisions.first?.changeReason, "Edited",
            "both the amounts and the time moved, so this is an ordinary edit")
        XCTAssertEqual(try store.activeIntakes().first { $0.id == id }?.occurredAt, now.addingTimeInterval(-3_600))
        XCTAssertEqual(try store.revisions(of: id).last?.components.first?.amount, 55)
    }

    /// An amounts-only save is unchanged by this rule: the time did not move, so it is an ordinary edit for
    /// the same reason it always was.
    func testEntryDetailRecordsAnAmountsOnlyEditAsAnOrdinaryEdit() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now, amount: 40)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.drafts["oats"] = "55"
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(model.revisions.first?.changeReason, "Edited")
    }

    /// A reason the person wrote is kept whatever it says, including on a time-only correction.
    func testEntryDetailKeepsAWrittenReasonOnATimeOnlyCorrection() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.changeReason = "lunch, not dinner"
        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(model.revisions.first?.changeReason, "lunch, not dinner")
    }

    /// The "When" picker edits the entry's time **in the zone the entry stores it in**, so a person sees and
    /// corrects the time the entry actually states. Picking 19:00 in a stored `America/Chicago` persists as
    /// 19:00 there, whichever zone the device happens to be in — otherwise the correction would be a
    /// different wall clock from the one it was made against.
    func testEntryDetailPicksTheTimeInTheEntriesStoredZoneNotTheDevices() throws {
        let store = try makeStore()
        let stored = try addFood(store, at: now, zone: "America/Chicago")
        let model = EntryDetailViewModel(store: store, intakeID: stored)
        model.load(now: now)
        XCTAssertEqual(model.storedTimeZone.identifier, "America/Chicago", "the picker is bound to the entry's own zone")

        // 19:00 on the day before the entry was logged, as a wall clock in the entry's zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let picked = try XCTUnwrap(
            calendar.date(from: DateComponents(
                timeZone: calendar.timeZone, year: 2023, month: 11, day: 13, hour: 19, minute: 0)))
        model.occurredAt = picked
        XCTAssertTrue(model.saveDrafts(now: now))

        let saved = try XCTUnwrap(try store.activeIntakes().first { $0.id == stored })
        XCTAssertEqual(saved.occurredAt, picked)
        // Read back in the stored zone, which is the only reading of it that is the 19:00 that was picked.
        let fields = Calendar(identifier: .gregorian)
            .dateComponents(in: calendar.timeZone, from: saved.occurredAt)
        XCTAssertEqual(fields.hour, 19, "the stored instant reads as 19:00 in the entry's own zone")
        XCTAssertEqual(fields.minute, 0)
    }

    /// An identifier the platform no longer resolves cannot be shown as a zone, so the picker falls back to
    /// the current one rather than being given something that is not a zone.
    func testEntryDetailFallsBackToTheCurrentZoneForAnIdentifierThatDoesNotResolve() throws {
        let store = try makeStore()
        let unresolved = try addFood(store, at: now, zone: "Not/AZone")
        let model = EntryDetailViewModel(store: store, intakeID: unresolved)
        model.load(now: now)
        XCTAssertEqual(
            model.storedTimeZone.identifier, TimeZone.current.identifier,
            "an identifier that does not resolve falls back to the zone this device is in")
    }

    /// The entry's amounts are the store's to hold, and the store accepts a zero the parser refuses: an
    /// amount of zero is a fact about a portion, not a mistake in typing. So a time correction must not
    /// re-read the untouched amounts as text, or such an entry could never have its time corrected at all —
    /// the one edit on the screen that changes nothing about the amounts.
    func testEntryDetailCorrectsTheTimeOfAnEntryWithAZeroValuedComponent() throws {
        let store = try makeStore()
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [
                IntakeComponent(componentID: "water", name: "Water", amount: 0, unit: .mL),
                IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g),
            ],
            product: nil, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        XCTAssertEqual(model.drafts["water"], "0", "the stored zero is what the field shows")
        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.saveDrafts(now: now), "an untouched zero must not fail the save: \(model.fieldErrors)")
        XCTAssertNil(model.fieldErrors["water"])

        let revision = try XCTUnwrap(try store.revisions(of: id).last)
        XCTAssertEqual(revision.changeReason, "Time corrected", "no amount changed, so it is a time correction")
        XCTAssertEqual(revision.components.first { $0.componentID == "water" }?.amount, 0)
        XCTAssertEqual(try store.activeIntakes().first { $0.id == id }?.occurredAt, now.addingTimeInterval(-3_600))
    }

    /// A stored `unknown` is the same case one step further on: the amount is not a number the parser accepts,
    /// so a save that changed only the time would fail on the field nobody touched and the entry could never
    /// be re-timed at all. The unknown is carried through as it stands, and since no amount changed the save
    /// is recorded as what it is.
    func testEntryDetailCorrectsTheTimeOfAnEntryWithAnUnknownAmount() throws {
        let id = "entry-unknown"
        let store = CannedStore(
            intakes: [Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC")],
            components: [id: [
                IntakeComponent(componentID: "seeds", name: "Seeds", amount: Decimal.nan, unit: .g),
                IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g),
            ]])

        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        XCTAssertEqual(model.drafts["seeds"], "", "an unknown amount seeds an empty field")
        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.saveDrafts(now: now), "an untouched unknown must not fail the save: \(model.fieldErrors)")
        XCTAssertNil(model.fieldErrors["seeds"])

        XCTAssertEqual(
            model.revisions.first?.changeReason, "Time corrected", "no amount changed, so it is a time correction")
        let written = try XCTUnwrap(store.lastEditedComponents)
        XCTAssertTrue(
            try XCTUnwrap(written.first { $0.componentID == "seeds" }).amount.isNaN,
            "the unknown is carried through unchanged, not dropped and not read as zero")
        XCTAssertEqual(try store.activeIntakes().first { $0.id == id }?.occurredAt, now.addingTimeInterval(-3_600))
    }

    /// Stating a number over an unknown is still a change, so the same save is an ordinary edit: the person
    /// said something the entry did not before.
    func testEntryDetailRecordsTypingOverAnUnknownAmountAsAnOrdinaryEdit() throws {
        let id = "entry-typed"
        let store = CannedStore(
            intakes: [Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC")],
            components: [id: [IntakeComponent(componentID: "seeds", name: "Seeds", amount: Decimal.nan, unit: .g)]])

        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.drafts["seeds"] = "30"
        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(model.revisions.first?.changeReason, "Edited")
        XCTAssertEqual(try store.revisions(of: id).last?.components.first?.amount, 30)
    }

    /// An amount the person **did** type is still held to the parser, zero included: the gate is on what was
    /// typed, not on what was stored.
    func testEntryDetailRefusesATypedZeroInAnAmountField() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.drafts["oats"] = "0"
        XCTAssertFalse(model.saveDrafts(now: now))
        XCTAssertNotNil(model.fieldErrors["oats"])
        XCTAssertEqual(try store.revisions(of: id).count, 1, "an invalid amount writes nothing")
    }

    /// Typing the amount back to the loaded one leaves nothing to save, so Save goes away. The message
    /// about the refused amount must go with it, or nothing on screen could clear it.
    func testEntryDetailClearsAFieldErrorWhenItsDraftChanges() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        let loaded = try XCTUnwrap(model.drafts["oats"])
        model.drafts["oats"] = "0"
        XCTAssertFalse(model.saveDrafts(now: now))
        XCTAssertNotNil(model.fieldErrors["oats"])
        model.drafts["oats"] = loaded
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.fieldErrors["oats"])
    }

    /// Only the field that was edited loses its message: another refused amount still needs correcting.
    func testEntryDetailKeepsTheErrorOfAFieldThatWasNotEdited() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        XCTAssertFalse(model.save(
            components: [
                EditedComponent(componentID: "oats", name: "Oats", amountText: "0", unit: .g),
                EditedComponent(componentID: "seeds", name: "Seeds", amountText: "0", unit: .g),
            ],
            changeReason: "Edited", now: now))
        XCTAssertNotNil(model.fieldErrors["oats"])
        XCTAssertNotNil(model.fieldErrors["seeds"])
        model.drafts["oats"] = "41"
        XCTAssertNil(model.fieldErrors["oats"])
        XCTAssertNotNil(model.fieldErrors["seeds"])
    }

    /// An amounts-only edit leaves the instant alone: nothing corrected it, so nothing may move.
    func testEntryDetailSaveWithoutATimeChangeLeavesTheStoredTimeAlone() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        model.drafts["oats"] = "55"
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertNil(store.lastEditOccurredAt)
        XCTAssertEqual(try store.activeIntakes().first { $0.id == id }?.occurredAt, now)
        XCTAssertEqual(model.revisions.first?.changeReason, "Edited")
    }

    /// A save before the first load cannot move an entry the model has not read: the draft is only
    /// a correction once `load` has said what the stored time was.
    func testEntryDetailSaveWithoutLoadCorrectsNothing() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        let saved = model.save(
            components: [EditedComponent(componentID: "oats", name: "Oats", amountText: "45", unit: .g)],
            changeReason: "Edited", now: now)
        XCTAssertTrue(saved)
        XCTAssertNil(store.lastEditOccurredAt)
        XCTAssertEqual(try store.activeIntakes().first { $0.id == id }?.occurredAt, now)
        XCTAssertEqual(try store.revisions(of: id).count, 2)
    }

    /// The entry leaves the day it was logged on for the day it was eaten on: the journal groups
    /// by the corrected instant, so yesterday's dinner is under yesterday.
    func testJournalMovesToDaySectionOfTheCorrectedTime() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        journal.load(now: now)
        XCTAssertEqual(journal.sections.map(\.id), ["2023-11-14"])

        let detail = EntryDetailViewModel(store: store, intakeID: id)
        detail.load(now: now)
        detail.occurredAt = now.addingTimeInterval(-86_400)
        XCTAssertTrue(detail.saveDrafts(now: now))

        journal.load(now: now)
        XCTAssertEqual(journal.sections.map(\.id), ["2023-11-13"])
        XCTAssertEqual(journal.sections.first?.rows.map(\.id), [id])
        XCTAssertEqual(journal.sections.first?.rows.first?.occurredAt, now.addingTimeInterval(-86_400))
    }

    func testInvalidEditAmountSetsFieldErrorAndWritesNothing() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        for text in ["", "abc", "0", "-5", "1,5,0", "1.2.3"] {
            XCTAssertFalse(model.save(components: [EditedComponent(componentID: "oats", name: "Oats", amountText: text, unit: .g)], changeReason: "x", now: now), text)
            XCTAssertNotNil(model.fieldErrors["oats"], text)
        }
        XCTAssertEqual(store.editCalls, 0)
        XCTAssertEqual(try store.revisions(of: id).count, 1)
    }

    func testFailedSaveKeepsPreviousRevisionAndShowsError() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now, amount: 40)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        store.failNextSaveForTesting = true
        XCTAssertFalse(model.save(components: [EditedComponent(componentID: "oats", name: "Oats", amountText: "99", unit: .g)], changeReason: "x", now: now))
        XCTAssertNotNil(model.errorMessage)
        let revisions = try store.revisions(of: id)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.components.first?.amount, 40)
        XCTAssertEqual(try store.activeIntakes().first?.currentRevision, 1)
    }

    func testDeleteQueuesDeleteOpsHidesEntryAndKeepsHistory() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        XCTAssertTrue(model.delete(now: now))
        XCTAssertEqual(store.deleteCalls, 1)
        XCTAssertTrue(model.isDeleted)
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.pendingOutbox().contains { $0.intakeID == id && $0.kind == .delete })
        XCTAssertEqual(try store.revisions(of: id).count, 1)
    }

    // MARK: Recents, favorites, library

    func testRecentsNewestFirstDistinctAndWithoutDeleted() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", at: now.addingTimeInterval(-300))
        try addFood(store, name: "Rice", at: now.addingTimeInterval(-200))
        try addFood(store, name: "Oats", at: now.addingTimeInterval(-100))
        let deleted = try addFood(store, name: "Beans", at: now)
        try store.delete(intakeID: deleted, now: now)
        let recents = try RecentItemsProvider(store: store).recents()
        XCTAssertEqual(recents.map(\.template.displayName), ["Oats", "Rice"])
        XCTAssertEqual(recents.first?.lastUsedAt, now.addingTimeInterval(-100))
    }

    func testRecentsDistinctByProductSnapshotAndLimitedTo20() throws {
        let store = try makeStore()
        try addFood(store, name: "Bar one", at: now.addingTimeInterval(-10), product: product("s1"))
        try addFood(store, name: "Bar renamed", at: now, product: product("s1"))
        XCTAssertEqual(try RecentItemsProvider(store: store).recents().count, 1)
        for index in 0..<25 { try addFood(store, name: "Item \(index)", at: now.addingTimeInterval(TimeInterval(index))) }
        XCTAssertEqual(try RecentItemsProvider(store: store).recents().count, 20)
    }

    func testFavoritesPersistAndFavoriteSurvivesDeleteOfItsIntake() throws {
        let directory = try makeDirectory()
        let store = try makeStore()
        let id = try addFood(store, name: "Oats", at: now)
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let library = LibraryViewModel(store: store, favorites: favorites)
        library.load()
        let recent = try XCTUnwrap(library.sections.last?.items.first)
        library.addFavorite(recent)
        try store.delete(intakeID: id, now: now)
        favorites.close()
        let reopened = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        XCTAssertEqual(try reopened.list().count, 1)
        XCTAssertEqual(try reopened.list().first?.components.first?.amountText, "40")
        let again = LibraryViewModel(store: store, favorites: reopened)
        again.load()
        XCTAssertEqual(again.sections.first?.items.count, 1)
    }

    func testLibraryOrderFavoritesBeforeRecentsAndSelectCreatesOnce() throws {
        let directory = try makeDirectory()
        let store = try makeStore()
        try addFood(store, name: "Oats", at: now.addingTimeInterval(-60))
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        try favorites.add(FavoriteTemplate(
            id: "f1", displayName: "Tea", category: "drink",
            components: [FavoriteComponent(componentID: "tea", name: "Tea", amountText: "250", unitSymbol: "mL")]))
        let library = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        library.load()
        XCTAssertEqual(library.sections.map(\.title), ["Favorites", "Foods", "Recents"])
        let tea = try XCTUnwrap(library.sections.first?.items.first)
        let before = store.createCalls
        let newID = library.select(tea, now: now)
        XCTAssertEqual(store.createCalls, before + 1)
        let created = try XCTUnwrap(try store.activeIntakes().first { $0.id == newID })
        XCTAssertEqual(created.category, "drink")
        XCTAssertEqual(created.occurredAt, now)
        let components = try store.revisions(of: created.id).first?.components
        XCTAssertEqual(components?.first?.amount, 250)
        XCTAssertEqual(components?.first?.unit, .mL)
    }

    // MARK: Review fixes

    private func makeFavorites() throws -> SwiftDataFavoritesStore {
        try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))
    }

    func testMalformedFavoriteAmountRejectsWholeTemplateAndCreatesNothing() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        try favorites.add(FavoriteTemplate(
            id: "bad", displayName: "Odd", category: "drink",
            components: [FavoriteComponent(componentID: "x", name: "X", amountText: "1.2.3", unitSymbol: "mL")]))
        XCTAssertNil(RepeatTemplate(favorite: try XCTUnwrap(favorites.list().first)))
        let library = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        library.load()
        let item = try XCTUnwrap(library.sections.first?.items.first)
        XCTAssertNil(library.select(item, now: now))
        XCTAssertEqual(store.createCalls, 0)
        XCTAssertTrue(try store.activeIntakes().isEmpty)
    }

    func testTimeZoneProviderIsResolvedAtCreateTime() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        try favorites.add(FavoriteTemplate(
            id: "f", displayName: "Tea", category: "drink",
            components: [FavoriteComponent(componentID: "tea", name: "Tea", amountText: "250", unitSymbol: "mL")]))
        var zone = "UTC"
        let library = LibraryViewModel(store: store, favorites: favorites, timeZoneProvider: { zone })
        library.load()
        let item = try XCTUnwrap(library.sections.first?.items.first)
        let first = try XCTUnwrap(library.select(item, now: now))
        zone = "Asia/Tokyo"
        let second = try XCTUnwrap(library.select(item, now: now))
        let intakes = try store.activeIntakes()
        XCTAssertEqual(intakes.first { $0.id == first }?.timeZoneIdentifier, "UTC")
        XCTAssertEqual(intakes.first { $0.id == second }?.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testFavoriteMealPersistsAcrossReopenAndRepeatCopiesIt() throws {
        let directory = try makeDirectory()
        let store = try makeStore()
        let url = directory.appendingPathComponent("favorites.store")
        let favorites = try SwiftDataFavoritesStore(url: url)
        try favorites.add(FavoriteTemplate(
            id: "f", displayName: "Oats", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "40", unitSymbol: "g")],
            meal: "breakfast"))
        favorites.close()
        let reopened = try SwiftDataFavoritesStore(url: url)
        XCTAssertEqual(try reopened.list().first?.meal, "breakfast")
        let library = LibraryViewModel(store: store, favorites: reopened, timeZoneIdentifier: "UTC")
        library.load()
        let item = try XCTUnwrap(library.sections.first?.items.first)
        let newID = try XCTUnwrap(library.select(item, now: now))
        XCTAssertEqual(try store.activeIntakes().first { $0.id == newID }?.meal, "breakfast")
    }

    /// The label a person picked is carried on the two screens they read an entry on, as words:
    /// "breakfast" is stored and "Breakfast" is what they see.
    func testMealLabelReachesTheJournalRowAndTheEntryDetail() throws {
        let store = try makeStore()
        let add = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        add.name = "Rolled oats"
        add.amountText = "40"
        add.meal = .breakfast
        XCTAssertTrue(add.save(now: now))
        let id = try XCTUnwrap(try store.activeIntakes().first?.id)

        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        journal.load(now: now)
        let row = try XCTUnwrap(journal.sections.first?.rows.first)
        XCTAssertEqual(row.meal, "Breakfast")
        XCTAssertTrue(row.accessibilityText.contains("Breakfast"), row.accessibilityText)

        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        XCTAssertEqual(today.rows.first?.meal, "Breakfast")

        let detail = EntryDetailViewModel(store: store, intakeID: id)
        detail.load(now: now)
        XCTAssertEqual(detail.mealText, "Breakfast")
    }

    /// An entry with no label says nothing rather than showing an empty or invented one.
    func testMealTextIsAbsentOnAnEntryThatStatesNoMeal() throws {
        let store = try makeStore()
        let id = try addFood(store, at: now)
        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        journal.load(now: now)
        XCTAssertNil(journal.sections.first?.rows.first?.meal)
        let detail = EntryDetailViewModel(store: store, intakeID: id)
        detail.load(now: now)
        XCTAssertNil(detail.mealText)
        XCTAssertNil(MealLabel.displayName(for: nil))
        XCTAssertNil(MealLabel.displayName(for: "  "))
    }

    func testFavoritingRecentTwiceLeavesOneFavoriteAndRecentIsMarked() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        try addFood(store, name: "Oats", at: now)
        let library = LibraryViewModel(store: store, favorites: favorites)
        library.load()
        let recent = try XCTUnwrap(library.sections.last?.items.first)
        library.addFavorite(recent)
        library.addFavorite(recent)
        XCTAssertEqual(try favorites.list().count, 1)
        XCTAssertEqual(library.sections.last?.items.first?.isFavorite, true)
    }

    /// The meal is part of an entry's identity in the Library. The same oats eaten at breakfast and at
    /// dinner are two entries a person adds again separately, so one favorite must not stand in for the
    /// other: without the meal in the key, the Dinner entry read as already favorited, `addFavorite`
    /// refused to save it as a second favorite, and removing the Breakfast one took the Dinner row with it.
    func testTwoMealsOfTheSameProductAreTwoRecentsAndTwoFavorites() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        try addFood(store, name: "Oats", at: now.addingTimeInterval(-60), product: product("snap-1"), meal: "breakfast")
        try addFood(store, name: "Oats", at: now, product: product("snap-1"), meal: "dinner")

        let recents = try RecentItemsProvider(store: store).recents()
        XCTAssertEqual(
            recents.count, 2, "the same product at two meals is two entries to add again, not one")

        let library = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        library.load()
        let breakfast = try XCTUnwrap(library.sections.last?.items.first { $0.template.meal == "breakfast" })
        let dinner = try XCTUnwrap(library.sections.last?.items.first { $0.template.meal == "dinner" })
        library.addFavorite(breakfast)
        library.addFavorite(dinner)
        XCTAssertEqual(
            try favorites.list().count, 2,
            "the Dinner entry is its own favorite, not a second write refused as a duplicate")
        library.load()
        XCTAssertTrue(library.sections.last?.items.allSatisfy(\.isFavorite) ?? false)

        // Removing one leaves the other: they were never the same favorite to begin with. The item is read
        // back off the reloaded sections, because `removeFavorite` only acts on one the model reports as
        // favorited.
        let favoritedDinner = try XCTUnwrap(
            library.sections.last?.items.first { $0.template.meal == "dinner" })
        XCTAssertTrue(favoritedDinner.isFavorite)
        library.removeFavorite(favoritedDinner)
        XCTAssertEqual(
            try favorites.list().map(\.meal).compactMap { $0 }, ["breakfast"],
            "removing the Dinner favorite leaves the Breakfast one: they were never one favorite")
    }

    /// An entry that states no meal keeps its own identity, and one stating none never collides with an
    /// entry stating an empty label — the key writes the meal as a counted part either way.
    func testAMealLessEntryIsStillItsOwnRecent() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", at: now.addingTimeInterval(-60))
        try addFood(store, name: "Oats", at: now, meal: "dinner")
        XCTAssertEqual(try RecentItemsProvider(store: store).recents().count, 2)
    }

    /// A meal spelled differently is still the same meal, so it is one identity. The stored column is free
    /// text in the export, so `"Breakfast "` reaches the store beside `"breakfast"` and the two must not
    /// become two recents and two favorites of one entry — the same failure the meal was added to the key to
    /// fix, reached by spelling rather than by value.
    func testTwoSpellingsOfOneMealAreOneIdentity() throws {
        let store = try makeStore()
        try addFood(
            store, name: "Oats", at: now.addingTimeInterval(-60), product: product("snap-1"), meal: "Breakfast ")
        try addFood(store, name: "Oats", at: now, product: product("snap-1"), meal: "breakfast")

        XCTAssertEqual(
            try RecentItemsProvider(store: store).recents().count, 1,
            "one meal spelled two ways is one entry to add again")

        let favorites = try makeFavorites()
        let library = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        library.load()
        let recent = try XCTUnwrap(library.sections.last?.items.first)
        library.addFavorite(recent)
        XCTAssertEqual(try favorites.list().count, 1)
        library.load()
        XCTAssertTrue(
            library.sections.last?.items.first?.isFavorite ?? false,
            "the recent reads as already favorited, as the row that shares its identity does")
    }

    func testRecentKeyDoesNotCollideOnPlusInNames() throws {
        let store = try makeStore()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: first, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "ab", name: "A+B", amount: 1, unit: .g)], product: nil, now: now)
        try store.create(
            Intake(id: second, category: "food", occurredAt: now.addingTimeInterval(1), timeZoneIdentifier: "UTC"),
            components: [
                IntakeComponent(componentID: "a", name: "A", amount: 1, unit: .g),
                IntakeComponent(componentID: "b", name: "B", amount: 1, unit: .g),
            ], product: nil, now: now.addingTimeInterval(1))
        XCTAssertEqual(try RecentItemsProvider(store: store).recents().count, 2)
    }

    func testSaveWithoutLoadKeepsProductAssociation() throws {
        let store = try makeStore()
        let id = try addFood(store, name: "Bar", at: now, product: product("snap-9"))
        let model = EntryDetailViewModel(store: store, intakeID: id)
        let saved = model.save(
            components: [EditedComponent(componentID: "bar", name: "Bar", amountText: "50", unit: .g)],
            changeReason: "Edited", now: now)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.lastEditProductSnapshotID, "snap-9")
    }

    func testRepeatWithMissingProductSnapshotCreatesNothingAndShowsMessage() throws {
        let store = try makeStore()
        let library = LibraryViewModel(store: store, favorites: try makeFavorites())
        let template = RepeatTemplate(
            displayName: "Bar", category: "food",
            components: [IntakeComponent(componentID: "bar", name: "Bar", amount: 1, unit: .g)],
            productSnapshotID: "missing-snapshot")
        let item = LibraryItem(id: "recent:x", title: "Bar", detail: "", isFavorite: false, template: template)
        XCTAssertNil(library.select(item, now: now))
        XCTAssertEqual(store.createCalls, 0)
        XCTAssertEqual(library.errorMessage, "The product for this item is no longer available.")
    }

    func testRecentWithZeroAmountCannotBeFavorited() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        try addFood(store, name: "Water", at: now, amount: 0)
        let library = LibraryViewModel(store: store, favorites: favorites)
        library.load()
        let recent = try XCTUnwrap(library.sections.last?.items.first)
        library.addFavorite(recent)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(try favorites.list().count, 0)
    }

    func testLoadClearsFieldErrorsAfterInvalidSave() throws {
        let store = try makeStore()
        let id = try addFood(store, name: "Oats", at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id)
        model.load(now: now)
        XCTAssertFalse(model.save(
            components: [EditedComponent(componentID: "oats", name: "Oats", amountText: "0", unit: .g)],
            changeReason: "Edited", now: now))
        XCTAssertNotNil(model.fieldErrors["oats"])
        model.load(now: now)
        XCTAssertTrue(model.fieldErrors.isEmpty)
    }
}
