import Foundation
import NutritionDomain
@testable import NutritionJournal
import XCTest
@testable import NutritionUI

/// A journal store that is never asked to read anything here, so the erase test only exercises the
/// screen's own bookkeeping.
private final class EraseStubStore: JournalStore, JournalRestoreProgress, @unchecked Sendable {
    private struct Unsupported: Error {}

    var failNextSaveForTesting = false
    var failClearRestoreForTesting = false
    func markRestoreInProgress(fileDigest: String) throws {}
    func restoreInProgressDigest() throws -> String? { nil }
    func clearRestoreInProgress() throws {
        if failClearRestoreForTesting { throw Unsupported() }
    }

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        throw Unsupported()
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision {
        throw Unsupported()
    }

    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil, unitRemovals: [String])throws -> IntakeRevision {
        throw Unsupported()
    }
    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { [] }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { [] }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { nil }
    func activeIntakesFromBackground() async throws -> [Intake] { [] }
    func close() {}
}

private final class EraseStubFavorites: FavoritesStore, @unchecked Sendable {
    struct Unsupported: Error {}
    func add(_ favorite: FavoriteTemplate) throws { throw Unsupported() }
    func remove(id: String) throws { throw Unsupported() }
    func list() throws -> [FavoriteTemplate] { [] }
    func contains(id: String) throws -> Bool { false }
    func close() {}
}

/// One injected store. `eraseCount` says the screen ran it; `failure` stands in for a store that
/// cannot erase, e.g. one that was closed.
private final class RecordingEraser: JournalErasing, @unchecked Sendable {
    let erasureName: String
    var eraseCount = 0
    var beforeErase: (() -> Void)?
    var failure: Error?

    init(failure: Error? = nil, name: String = "test store") {
        self.failure = failure
        self.erasureName = name
    }

    func eraseAll() throws {
        beforeErase?()
        eraseCount += 1
        if let failure { throw failure }
    }
}

private actor AsyncEraseGate {
    private var isOpen = false
    private var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        hasEntered = true
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func entered() -> Bool { hasEntered }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct EraseFailure: Error {}
private struct RemoveFailure: Error {}

@MainActor
final class ConnectionsPrivacyEraseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_705_313_700)

    private func makeModel(_ erasers: [JournalErasing]) -> ConnectionsPrivacyViewModel {
        ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: erasers)
    }

    // MARK: - The Health delivery gate (#841)

    private func makeModel(
        _ eraser: RecordingEraser, gate: DeliveryRunGate, waitSeconds: TimeInterval = 5,
        eraseLocalAccount: @escaping () async throws -> Void = {}
    ) -> ConnectionsPrivacyViewModel {
        ConnectionsPrivacyViewModel(
            goals: InMemoryGoalStore(), store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [eraser],
            eraseLocalAccount: eraseLocalAccount, deliveryGate: gate, deliveryWaitSeconds: waitSeconds)
    }

    /// An erase that finds a Health pass running waits for it before it touches any store. Checked by order, not by
    /// a time window (#1001): the erase's wait on the gate is seen to start, and while it waits no store is touched.
    func testEraseWaitsForARunningHealthPassBeforeTouchingAStore() async {
        let waits = GateWaitWatcher()
        let gate = DeliveryRunGate(schedule: waits.schedule)
        let eraser = RecordingEraser()
        let model = makeModel(eraser, gate: gate)
        await gate.enter() // a delivery pass is running
        let erase = Task { await model.eraseAllData() }
        // The erase is now queued on the gate: it scheduled its timeout, which only a waiting pause does. An erase
        // that skipped the gate would never get here, and this bounded poll would fail instead of hanging.
        let deadline = Date().addingTimeInterval(5)
        var waiting = await waits.started
        while !waiting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waiting = await waits.started
        }
        XCTAssertTrue(waiting, "the erase waits on the gate while the pass runs")
        XCTAssertEqual(eraser.eraseCount, 0, "no store is touched while the pass runs")
        await gate.leave()
        guard let erased = await finished(erase) else {
            return XCTFail("the erase never finished after the pass ended")
        }
        XCTAssertTrue(erased)
        XCTAssertEqual(eraser.eraseCount, 1)
    }

    /// A pass that is still running after the wait leaves everything in place: nothing erased, and Retry offered.
    func testEraseGivesUpAfterTheWaitWithNothingErasedAndOffersRetry() async {
        let gate = DeliveryRunGate()
        let eraser = RecordingEraser()
        let model = makeModel(eraser, gate: gate, waitSeconds: 0.05)
        await gate.enter()
        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)
        XCTAssertEqual(eraser.eraseCount, 0, "nothing is erased")
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseNothingErasedMessage)
        XCTAssertTrue(model.eraseRetryAvailable)
        await gate.leave()
    }

    /// A pass that arrives while the erase runs cannot start until the erase is done.
    func testAPassCannotStartWhileTheEraseHoldsTheGate() async {
        let gate = DeliveryRunGate()
        var passCouldStart: Bool?
        let model = makeModel(RecordingEraser(), gate: gate, eraseLocalAccount: {
            passCouldStart = await gate.pause(upTo: 0.05) != nil
        })
        _ = await model.eraseAllData()
        XCTAssertEqual(passCouldStart, false, "the erase holds the delivery gate while it runs")
    }

    /// The erase lets go of the gate on every exit: after a success, a failed store, and a timed-out wait.
    func testEraseReleasesTheGateOnEveryExit() async {
        for failing in [false, true] {
            let gate = DeliveryRunGate()
            let model = makeModel(RecordingEraser(failure: failing ? EraseFailure() : nil), gate: gate)
            _ = await model.eraseAllData()
            let free = await gate.pause(upTo: 0.5)
            XCTAssertNotNil(free, "the gate is free after an erase that \(failing ? "failed" : "succeeded")")
            await gate.resume(free)
        }
        // Timed out: the erase never held the gate, so it releases nothing the pass still holds.
        let gate = DeliveryRunGate()
        let model = makeModel(RecordingEraser(), gate: gate, waitSeconds: 0.05)
        await gate.enter()
        _ = await model.eraseAllData()
        let stillHeld = await gate.pause(upTo: 0.05)
        XCTAssertNil(stillHeld, "a timed-out erase does not release the running pass's hold")
        await gate.leave()
        let freeAfterPass = await gate.pause(upTo: 0.5)
        XCTAssertNotNil(freeAfterPass, "the gate is free once the pass ends")
    }

    func testDeliveryGateClosesBeforeFirstEraserEvenWhenEraseFails() async {
        var closed = false
        let eraser = RecordingEraser(failure: EraseFailure())
        eraser.beforeErase = { XCTAssertTrue(closed) }
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: EraseStubStore(), erasers: [eraser], beforeErase: { closed = true })
        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)
        XCTAssertTrue(closed)
        XCTAssertEqual(eraser.eraseCount, 1)
    }

    func testSuccessfulEraseCallbackRunsAfterAllErasersAndNeverAfterFailure() async {
        for fails in [false, true] {
            var closed = false, finished = false
            let first = RecordingEraser(), last = RecordingEraser(failure: fails ? EraseFailure() : nil)
            first.beforeErase = { XCTAssertTrue(closed); XCTAssertFalse(finished) }
            last.beforeErase = { XCTAssertTrue(closed); XCTAssertFalse(finished) }
            let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: EraseStubStore(), erasers: [first, last], beforeErase: { closed = true }, afterSuccessfulErase: {
                XCTAssertEqual(first.eraseCount, 1); XCTAssertEqual(last.eraseCount, 1); finished = true
            })
            let erased = await model.eraseAllData()
            XCTAssertEqual(erased, !fails)
            XCTAssertEqual(finished, !fails)
        }
    }

    func testEraseAllDataRunsEveryInjectedStore() async {
        let journal = RecordingEraser()
        let favorites = RecordingEraser()
        let recipes = RecordingEraser()
        let goals = RecordingEraser()
        let model = makeModel([journal, favorites, recipes, goals])
        XCTAssertTrue(model.canEraseAll)

        let eraseResult1 = await model.eraseAllData()
        XCTAssertTrue(eraseResult1)

        XCTAssertEqual(journal.eraseCount, 1)
        XCTAssertEqual(favorites.eraseCount, 1)
        XCTAssertEqual(recipes.eraseCount, 1)
        // A daily goal is what the person is aiming at every day, so it goes with the entries it
        // was measured against rather than outliving them.
        XCTAssertEqual(goals.eraseCount, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entryCount, 0)
    }

    /// The exported copy holds the same history as the stores, so it is deleted rather than left in the
    /// temporary directory with nothing able to remove it.
    func testEraseAllDataRemovesTheExportFileAndResetsTheExportState() async throws {
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [RecordingEraser()])
        XCTAssertTrue(model.export(now: now))
        let url = try XCTUnwrap(model.exportFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(model.exportState, .ready)

        let eraseResult2 = await model.eraseAllData()
        XCTAssertTrue(eraseResult2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(model.exportFileURL)
        XCTAssertNil(model.exportFileName)
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertNil(model.errorMessage)
    }

    /// The erase blocks imports before it awaits local Keychain cleanup, so a late import cannot
    /// repopulate the journal while the account cleanup is suspended.
    func testEraseMarksBusyBeforeAwaitingLocalAccountCleanup() async {
        let gate = AsyncEraseGate()
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [RecordingEraser()],
            eraseLocalAccount: { await gate.pause() })
        let erasing = Task { await model.eraseAllData() }
        // Bounded, so an erase that never reaches the account cleanup fails here instead of hanging the run.
        var entered = await gate.entered()
        let deadline = Date().addingTimeInterval(5)
        while !entered, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            entered = await gate.entered()
        }
        XCTAssertTrue(entered, "the erase reached the account cleanup")

        model.importJournal(data: Data("[]".utf8))

        XCTAssertEqual(model.importState, .failed)
        XCTAssertEqual(model.importMessage, ConnectionsPrivacyViewModel.importDuringEraseMessage)
        await gate.open()
        guard let erased = await finished(erasing) else {
            return XCTFail("the erase never finished after the account cleanup was let go")
        }
        XCTAssertTrue(erased)
    }

    /// One store that cannot erase must not stop the others, and the person has to be told that
    /// something was left behind.
    func testAStoreThatFailsIsReportedAndTheRestStillRun() async {
        let failing = RecordingEraser(failure: EraseFailure(), name: "goals")
        let working = RecordingEraser()
        let model = makeModel([failing, working])

        let eraseResult3 = await model.eraseAllData()
        XCTAssertFalse(eraseResult3)

        XCTAssertEqual(failing.eraseCount, 1)
        XCTAssertEqual(working.eraseCount, 1)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseLeftBehindMessage(["goals"]))
        XCTAssertTrue(model.eraseRetryAvailable)
        XCTAssertEqual(model.exportState, .idle)
        XCTAssertEqual(model.entryCount, 0)
    }

    /// A reminder request still pending after the erase is reported as "reminders" still on the phone.
    func testARemainingReminderRequestIsReportedAsStillOnThePhone() async {
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [RecordingEraser()],
            remindersStillPending: { ["reminders"] })

        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseLeftBehindMessage(["reminders"]))
    }

    /// A custom reminder request still pending after the erase is reported as "custom reminders" still on the phone.
    func testARemainingCustomReminderIsReportedAsStillOnThePhone() async {
        let center = FakePendingReminderCenter(["custom-reminder-\(UUID().uuidString)"])
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [RecordingEraser()],
            remindersStillPending: { await ReminderReadback.namesStillPending(in: center, pause: {}) })

        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseLeftBehindMessage(["custom reminders"]))
    }

    /// The erase list keeps each store instance it was given, in the pinned order: the builder returns the same
    /// objects, not copies with matching names.
    func testTheEraseOrderBuilderKeepsTheExactInstancesInOrder() {
        let log = EraseOrderLog()
        let widgets = OrderedEraser("widget data", log)
        let savedMeals = OrderedEraser("saved meals", log)
        let supplements = OrderedEraser("supplements", log)
        let daily = OrderedEraser("reminders", log)
        let custom = OrderedEraser("custom reminders", log)
        let journal = OrderedEraser("journal", log)
        let favorites = OrderedEraser("favorites", log)
        let recipes = OrderedEraser("recipes", log)
        let goals = OrderedEraser("goals", log)

        let order = ConnectionsPrivacyViewModel.eraseOrder(ConnectionsPrivacyViewModel.EraseStores(
            widgets: widgets, savedMeals: savedMeals, supplements: supplements,
            reminders: [daily, custom], journal: journal, favorites: favorites, recipes: recipes, goals: goals))

        let expected: [JournalErasing] = [
            widgets, savedMeals, supplements, daily, custom, journal, favorites, recipes, goals,
        ]
        XCTAssertEqual(order.count, expected.count)
        for (actual, wanted) in zip(order, expected) {
            XCTAssertTrue(actual === wanted, "\(wanted.erasureName) is not the instance the builder was given")
        }
    }

    /// Erase and Retry only ask for confirmation: nothing is erased until the person confirms.
    func testARequestedEraseErasesNothingUntilConfirmed() async {
        let eraser = RecordingEraser()
        let model = makeModel([eraser])
        model.requestErase()
        XCTAssertTrue(model.eraseConfirmationPending)
        XCTAssertEqual(eraser.eraseCount, 0)

        model.cancelEraseRequest()
        XCTAssertFalse(model.eraseConfirmationPending)
        XCTAssertEqual(eraser.eraseCount, 0)

        model.requestErase()
        let erased = await model.confirmErase()
        XCTAssertTrue(erased)
        XCTAssertEqual(eraser.eraseCount, 1)
        XCTAssertFalse(model.eraseConfirmationPending)
    }

    /// The erase runs the stores in the order the app builds them: widget data first, journal after the lists.
    func testTheEraseOrderIsWidgetFirstAndJournalAfterTheLists() async {
        let log = EraseOrderLog()
        let order = ConnectionsPrivacyViewModel.eraseOrder(ConnectionsPrivacyViewModel.EraseStores(
            widgets: OrderedEraser("widget data", log), savedMeals: OrderedEraser("saved meals", log),
            supplements: OrderedEraser("supplements", log),
            reminders: [OrderedEraser("reminders", log), OrderedEraser("custom reminders", log)],
            journal: OrderedEraser("journal", log), favorites: OrderedEraser("favorites", log),
            recipes: OrderedEraser("recipes", log), goals: OrderedEraser("goals", log)))
        let model = makeModel(order)

        let erased = await model.eraseAllData()
        XCTAssertTrue(erased)
        XCTAssertEqual(log.names, [
            "widget data", "saved meals", "supplements", "reminders", "custom reminders",
            "journal", "favorites", "recipes", "goals",
        ])
    }

    /// Community sharing is paused only once the erase is going ahead. A restore flag that cannot be cleared
    /// stops the erase before the stores, so it must not pause sharing.
    func testBeforeEraseDoesNotRunWhenTheFlagCannotBeCleared() async {
        let store = EraseStubStore()
        store.failClearRestoreForTesting = true
        var paused = false
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: store, favorites: EraseStubFavorites(), erasers: [RecordingEraser()],
            beforeErase: { paused = true })

        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)
        XCTAssertFalse(paused)
    }

    /// Every store still on the phone is named, in the order the erase ran, and none of them stops the rest.
    func testEverySurvivingStoreIsNamedInEraseOrder() async {
        let savedMeals = RecordingEraser(failure: EraseFailure(), name: "saved meals")
        let working = RecordingEraser()
        let journal = RecordingEraser(failure: EraseFailure(), name: "journal")
        let goals = RecordingEraser(failure: EraseFailure(), name: "goals")
        let model = makeModel([savedMeals, working, journal, goals])

        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)

        XCTAssertEqual(working.eraseCount, 1)
        XCTAssertEqual(goals.eraseCount, 1)
        XCTAssertEqual(
            model.errorMessage,
            "Erase didn't finish. Still on this device: saved meals, journal and goals. Tap Retry to erase them.")
    }

    /// A restore flag that cannot be cleared stops the erase before any store is touched, and says so.
    func testNothingIsErasedWhenTheRestoreFlagCannotBeCleared() async {
        let store = EraseStubStore()
        store.failClearRestoreForTesting = true
        let journal = RecordingEraser(name: "journal")
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(), store: store, favorites: EraseStubFavorites(), erasers: [journal])

        let erased = await model.eraseAllData()
        XCTAssertFalse(erased)

        XCTAssertEqual(journal.eraseCount, 0)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseNothingErasedMessage)
        XCTAssertTrue(model.eraseRetryAvailable)

        store.failClearRestoreForTesting = false
        let retried = await model.eraseAllData()
        XCTAssertTrue(retried)
        XCTAssertEqual(journal.eraseCount, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.eraseRetryAvailable)
    }

    /// A local account-keychain failure is included in the partial result, while every other local eraser still runs.
    func testLocalAccountEraseFailureDoesNotStopOtherErasers() async {
        let journal = RecordingEraser()
        var accountEraseCount = 0
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [journal],
            eraseLocalAccount: {
                accountEraseCount += 1
                throw EraseFailure()
            })

        let eraseResult = await model.eraseAllData()
        XCTAssertFalse(eraseResult)

        XCTAssertEqual(accountEraseCount, 1)
        XCTAssertEqual(journal.eraseCount, 1)
        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseLeftBehindMessage(["community sign-in"]))
    }

    /// With no store injected there is nothing to erase, so the screen does not offer the action at all
    /// rather than reporting that an erase it never ran succeeded.
    func testTheActionIsNotOfferedWithoutAnInjectedStore() async {
        let model = makeModel([])
        XCTAssertFalse(model.canEraseAll)
        let eraseResult4 = await model.eraseAllData()
        XCTAssertTrue(eraseResult4)
        XCTAssertNil(model.errorMessage)
    }

    /// An export this screen never made still belongs to the app and still holds the journal: the app
    /// can be killed after an export and relaunched into a model that has forgotten the URL. The erase
    /// has to sweep the temporary directory, not only the one file this model remembers.
    func testEraseRemovesEveryExportFileEvenOneThisScreenNeverWrote() async throws {
        let writtenEarlier = ConnectionsPrivacyViewModel.exportFileURL(for: now.addingTimeInterval(-86_400))
        let stray = ConnectionsPrivacyViewModel.exportFileURL(for: now.addingTimeInterval(-172_800))
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-\(UUID().uuidString).txt")
        for url in [writtenEarlier, stray, unrelated] {
            try Data("{}".utf8).write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        }
        // A screen that has exported nothing this session, which is the case the finding is about.
        let model = makeModel([RecordingEraser()])
        XCTAssertNil(model.exportFileURL)

        let eraseResult5 = await model.eraseAllData()
        XCTAssertTrue(eraseResult5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenEarlier.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        // Only this app's own exports are removed: a file the app did not write is none of its business.
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// A name that only looks like an export is not this app's file, and an erase that deletes it would
    /// be destroying something it never wrote.
    func testEraseLeavesAMalformedExportNameAlone() async throws {
        let malformed = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-export-.json")
        let shortStamp = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-export-2024-1-15-101500.json")
        for url in [malformed, shortStamp] {
            try Data("{}".utf8).write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        }
        let model = makeModel([RecordingEraser()])

        let eraseResult6 = await model.eraseAllData()
        XCTAssertTrue(eraseResult6)

        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortStamp.path))
    }

    /// A file that cannot be removed is an erase that did not finish. Reporting success would promise a
    /// deletion that never happened, so the failure is reported like a store's.
    func testEraseReportsFailureWhenAnExportFileCannotBeRemoved() async throws {
        let stray = ConnectionsPrivacyViewModel.exportFileURL(for: now.addingTimeInterval(-86_400))
        try Data("{}".utf8).write(to: stray)
        addTeardownBlock { try? FileManager.default.removeItem(at: stray) }
        let model = ConnectionsPrivacyViewModel(goals: InMemoryGoalStore(),
            store: EraseStubStore(), favorites: EraseStubFavorites(), erasers: [RecordingEraser()],
            remover: { url in if url == stray { throw RemoveFailure() } })

        let eraseResult7 = await model.eraseAllData()
        XCTAssertFalse(eraseResult7)

        XCTAssertEqual(model.errorMessage, ConnectionsPrivacyViewModel.eraseLeftBehindMessage(["export files"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    /// The export names the sweep looks for have to be the names the exporter writes, or the sweep
    /// matches nothing and every strayed export survives. A name it matches wrongly is just as bad: it
    /// deletes a file this app never wrote.
    func testTheSweepPatternMatchesTheNamesTheExporterWrites() async throws {
        let model = makeModel([RecordingEraser()])
        XCTAssertTrue(model.export(now: now.addingTimeInterval(-86_400)))
        let url = try XCTUnwrap(model.exportFileURL)
        let name = url.lastPathComponent
        XCTAssertTrue(ConnectionsPrivacyViewModel.exportFilePatternMatches(name), name)
        for rejected in [
            "journal-export-.json",
            "journal-export-2024-1-15-101500.json",
            "journal-export-2024-01-15-101500.txt",
            "journal-export-2024-01-15T101500.json",
            "some-other-export-2024-01-15-101500.json",
            "journal-export-2024-01-15-101500.json.bak",
            "journal-export-2024-99-99-999999.json",
            "journal-export-2024-02-30-101500.json",
        ] {
            XCTAssertFalse(ConnectionsPrivacyViewModel.exportFilePatternMatches(rejected), rejected)
        }
        await model.eraseAllData()
    }

    /// The host has to be able to see that an erase happened, or the tabs showing cached entries reload
    /// only on some unrelated state change.
    func testErasingBumpsTheGenerationAHostWatches() async {
        let model = makeModel([RecordingEraser()])
        XCTAssertEqual(model.eraseGeneration, 0)
        await model.eraseAllData()
        XCTAssertEqual(model.eraseGeneration, 1)
        await model.eraseAllData()
        XCTAssertEqual(model.eraseGeneration, 2)
    }

    /// The confirmation the button is guarded by has to say what goes and that it cannot be undone.
    func testTheConfirmationTextSaysWhatIsRemovedAndThatItCannotBeUndone() {
        XCTAssertFalse(ConnectionsPrivacyViewModel.eraseConfirmationMessage.isEmpty)
        let message = ConnectionsPrivacyViewModel.eraseConfirmationMessage.lowercased()
        XCTAssertTrue(message.contains("entry"))
        XCTAssertTrue(message.contains("favorite"))
        XCTAssertTrue(message.contains("recipe"))
        XCTAssertTrue(message.contains("saved meal"), "saved meals are erased too, so the warning says so")
        XCTAssertTrue(message.contains("supplement"), "the supplement list is erased too, so the warning says so")
        XCTAssertTrue(ConnectionsPrivacyViewModel.eraseFooterMessage.lowercased().contains("saved meals"))
        XCTAssertTrue(ConnectionsPrivacyViewModel.eraseFooterMessage.lowercased().contains("supplement list"))
        XCTAssertTrue(message.contains("goal"), "goals are erased too, so the warning says so")
        XCTAssertTrue(ConnectionsPrivacyViewModel.eraseFooterMessage.lowercased().contains("goal"))
        XCTAssertTrue(message.contains("reminder"), "the daily reminder is switched off too, so the warning says so")
        XCTAssertTrue(ConnectionsPrivacyViewModel.eraseFooterMessage.lowercased().contains("reminder"))
        XCTAssertTrue(message.contains("cannot be undone"))
        XCTAssertTrue(message.contains("signs you out"))
        XCTAssertTrue(message.contains("community account"))
        XCTAssertTrue(message.contains("shared labels remain"))
        XCTAssertEqual(ConnectionsPrivacyViewModel.eraseButtonTitle, "Erase all data")
    }

    /// Erasing the journal does not remove Health samples, so both erase surfaces must say so.
    func testTheConfirmationAndFooterSayHealthSamplesStay() {
        for text in [
            ConnectionsPrivacyViewModel.eraseConfirmationMessage,
            ConnectionsPrivacyViewModel.eraseFooterMessage,
        ] {
            XCTAssertTrue(text.contains("in the Health app"), text)
            XCTAssertTrue(text.contains("stays there"), text)
        }
    }

    /// A copy the person already shared or saved elsewhere is not reachable from here, and saying
    /// otherwise would let someone erase their journal and leave a shared copy behind not knowing.
    func testTheConfirmationAndFooterWarnThatASharedCopyIsNotErased() {
        let texts = [
            ConnectionsPrivacyViewModel.eraseConfirmationMessage,
            ConnectionsPrivacyViewModel.eraseFooterMessage,
        ]
        for text in texts {
            let message = text.lowercased()
            XCTAssertTrue(message.contains("shared") || message.contains("saved"), message)
            XCTAssertTrue(message.contains("files"), message)
            XCTAssertTrue(message.contains("mail"), message)
            XCTAssertTrue(message.contains("another app"), message)
            XCTAssertTrue(message.contains("delete it"), message)
            // The wording that made this false must not come back.
            XCTAssertFalse(message.contains("nothing has to be deleted"), message)
            XCTAssertFalse(message.contains("nothing needs deleting"), message)
            XCTAssertFalse(message.contains("nothing needs to be deleted"), message)
        }
    }
}

/// Records the order the erase calls each store in.
private final class EraseOrderLog: @unchecked Sendable {
    var names: [String] = []
}

private final class OrderedEraser: JournalErasing, @unchecked Sendable {
    let erasureName: String
    private let log: EraseOrderLog

    init(_ name: String, _ log: EraseOrderLog) {
        erasureName = name
        self.log = log
    }

    func eraseAll() throws {
        log.names.append(erasureName)
    }
}

/// A notification center whose pending requests are fixed by the test.
struct FakePendingReminderCenter: PendingReminderCenter {
    let identifiers: [String]
    init(_ identifiers: [String]) { self.identifiers = identifiers }
    func pendingRequestIdentifiers() async -> [String] { identifiers }
}

/// Records that a pause on the delivery gate started waiting, by its scheduling a timeout that never fires. The erase
/// test uses it to know the erase is queued on the gate (#1001).
private actor GateWaitWatcher {
    private(set) var started = false

    nonisolated var schedule: DeliveryRunGate.Schedule {
        { _, _ in Task { await self.markStarted() } }
    }

    private func markStarted() { started = true }
}

/// The value of `task`, or nil when it has not finished within `seconds`, so a broken gate fails the waiting assertion
/// instead of hanging the run. A task that never finishes is left behind; the test has already failed by then.
private func finished<T: Sendable>(_ task: Task<T, Never>, within seconds: TimeInterval = 5) async -> T? {
    let once = ResumeOnce<T?>()
    return await withCheckedContinuation { continuation in
        Task { once.resume(continuation, with: await task.value) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.resume(continuation, with: nil)
        }
    }
}

/// Resumes a continuation at most once, for whichever of two racing tasks gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resume(_ continuation: CheckedContinuation<T, Never>, with value: T) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { continuation.resume(returning: value) }
    }
}
