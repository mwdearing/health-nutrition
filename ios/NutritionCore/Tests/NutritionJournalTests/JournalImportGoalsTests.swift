import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// Goals in a version 8 export: restored add-only, never over a goal the device already has.
final class JournalImportGoalsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func journal() throws -> SwiftDataJournalStore {
        let store = try SwiftDataJournalStore(url: try directory().appendingPathComponent("journal.store"))
        addTeardownBlock { store.close() }
        return store
    }

    private func goalStore() throws -> SwiftDataGoalStore {
        let store = try SwiftDataGoalStore(url: try directory().appendingPathComponent("goals.store"))
        addTeardownBlock { store.close() }
        return store
    }

    /// A document with no entries and only the given goals, encoded as the app writes it.
    private func goalsExport(_ goals: [JournalExportGoal], schemaVersion: Int = JournalExport.currentSchemaVersion) throws -> Data {
        try JournalExporter.encode(
            JournalExport(
                schemaVersion: schemaVersion, exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: "test", intakes: [], tombstones: [], favorites: [], goals: goals))
    }

    private let protein = JournalExportGoal(nutrient: "protein", target: "60", unit: "g")

    func testAMissingGoalIsAddedAndCounted() throws {
        let goals = try goalStore()
        let summary = try JournalImporter.importExport(
            try goalsExport([protein]), into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(try goals.goal(for: "protein")?.target, Decimal(60))
        XCTAssertEqual(summary.goals, 1)
    }

    func testAnExistingGoalIsNeverReplaced() throws {
        let goals = try goalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(80), unit: .g))
        let summary = try JournalImporter.importExport(
            try goalsExport([protein]), into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(try goals.goal(for: "protein")?.target, Decimal(80))
        XCTAssertEqual(summary.goals, 0)
    }

    func testReimportingTheSameFileChangesNothing() throws {
        let goals = try goalStore()
        let data = try goalsExport([protein])
        _ = try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: goals)
        let again = try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(try goals.goals().map(\.nutrient), ["protein"])
        XCTAssertEqual(again.goals, 0)
    }

    func testGoalsInFileWithoutAGoalsStoreAreRefused() throws {
        XCTAssertThrowsError(
            try JournalImporter.importExport(try goalsExport([protein]), into: try journal(), favorites: nil, goals: nil)
        ) { error in
            guard case JournalImportError.corrupt = error else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    /// The same document with one change made to its JSON, so a shape rule is tested on the bytes a file carries.
    private func mutated(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testAVersion8FileWithGoalsIsAccepted() throws {
        let goals = try goalStore()
        let summary = try JournalImporter.importExport(
            try goalsExport([protein]), into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(summary.goals, 1)
    }

    func testAnUnknownKeyInsideAGoalIsRefusedAsMalformed() throws {
        let data = try mutated(try goalsExport([protein])) { root in
            var list = root["goals"] as? [[String: Any]] ?? []
            list[0]["extra"] = "x"
            root["goals"] = list
        }
        XCTAssertThrowsError(
            try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: try goalStore())
        ) { error in
            guard case JournalImportError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testAnUnknownRootKeyInVersion8IsRefusedAsMalformed() throws {
        let data = try mutated(try goalsExport([protein])) { root in
            root["extra"] = "x"
        }
        XCTAssertThrowsError(
            try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: try goalStore())
        ) { error in
            guard case JournalImportError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    private let energy = JournalExportGoal(nutrient: "energy", target: "2000", unit: "kcal")

    func testARestoreReceiptIsNotAGoalAndIsNotExported() throws {
        let goals = try goalStore()
        try goals.recordGoalRestoreReceipt("digest-a", goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])
        XCTAssertTrue(try goals.goals().isEmpty, "a receipt row must not read back as a goal")
        let export = try JournalExporter.makeExport(
            store: try journal(), goals: goals, appVersion: "test", exportedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(export.goals.isEmpty, "a receipt row must not export as a goal")
    }

    func testAnUnreadableReceiptFailsClosed() throws {
        let goals = try goalStore()
        try goals.recordGoalRestoreReceipt("bad", goals: [])
        try goals.writeCorruptTargetForTesting(nutrient: "restore-receipt:bad", targetText: "not json")
        XCTAssertThrowsError(try goals.goalRestoreReceipt("bad"))
    }

    func testAStopAfterTheReceiptRemovesItAndWritesNoGoal() throws {
        let base = try goalStore()
        let store = ScriptedGoalStore(base: base) { _, _ in throw JournalImportError.corrupt("stopped") }
        let data = try goalsExport([protein, energy])
        XCTAssertThrowsError(try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: store))
        XCTAssertNil(try base.goalRestoreReceipt(JournalImporter.fileDigest(data)))
        XCTAssertTrue(try base.goals().isEmpty)
    }

    func testAUserChangedGoalSurvivesUndo() throws {
        let base = try goalStore()
        var calls = 0
        let store = ScriptedGoalStore(base: base) { _, base in
            calls += 1
            if calls == 2 {
                // The person sets protein to 90 while the restore is writing energy, then the write fails.
                try base.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(90), unit: .g))
                throw JournalImportError.corrupt("stopped")
            }
        }
        XCTAssertThrowsError(try JournalImporter.importExport(
            try goalsExport([protein, energy]), into: try journal(), favorites: nil, goals: store))
        XCTAssertEqual(try base.goal(for: "protein")?.target, Decimal(90))
        XCTAssertNil(try base.goal(for: "energy"))
    }

    func testAKeyThatWasNeverWrittenIsANoOpOnUndo() throws {
        let base = try goalStore()
        try base.setGoal(NutrientGoal(nutrient: "sodium", target: Decimal(2300), unit: .mg))
        let store = ScriptedGoalStore(base: base) { _, _ in throw JournalImportError.corrupt("stopped") }
        XCTAssertThrowsError(try JournalImporter.importExport(
            try goalsExport([protein, energy]), into: try journal(), favorites: nil, goals: store))
        XCTAssertEqual(try base.goals().map(\.nutrient), ["sodium"], "undo must not touch a goal it did not set")
    }

    /// A stop after the receipt and before any goal: the flag and the receipt are there, no goal is. Importing the same
    /// file again adds exactly the recorded goals and removes the receipt. The flag is set the way the favorites
    /// resume test sets it, by marking the file in progress over an empty journal.
    func testAStopAfterTheReceiptIsFinishedByImportingTheSameFileAgain() throws {
        let base = try goalStore()
        let data = try goalsExport([protein, energy])
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try base.recordGoalRestoreReceipt(digest, goals: [
            NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g),
            NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .kcal),
        ])

        let summary = try JournalImporter.importExport(data, into: journal, favorites: nil, goals: base)

        XCTAssertEqual(summary.goals, 2)
        XCTAssertEqual(try base.goal(for: "protein")?.target, Decimal(60))
        XCTAssertEqual(try base.goal(for: "energy")?.target, Decimal(2000))
        XCTAssertNil(try base.goalRestoreReceipt(digest), "a finished resume removes its receipt")
        XCTAssertNil(try journal.restoreInProgressDigest(), "a finished resume clears its flag")
    }

    /// A stop before the receipt: the flag is there and no goal is, and no receipt either. Importing again records the
    /// missing goals first and writes them.
    func testAStopBeforeTheReceiptIsFinishedByImportingTheSameFileAgain() throws {
        let base = try goalStore()
        let data = try goalsExport([protein])
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)

        let summary = try JournalImporter.importExport(data, into: journal, favorites: nil, goals: base)

        XCTAssertEqual(summary.goals, 1)
        XCTAssertEqual(try base.goal(for: "protein")?.target, Decimal(60))
        XCTAssertNil(try base.goalRestoreReceipt(digest))
    }

    /// Undo of what a resume set removes exactly the recorded goals, and leaves a goal the person set on their own.
    func testUndoAfterAResumeRemovesOnlyTheRecordedGoals() throws {
        let base = try goalStore()
        try base.setGoal(NutrientGoal(nutrient: "sodium", target: Decimal(2300), unit: .mg))
        let recorded = [
            NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g),
            NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .kcal),
        ]
        for goal in recorded { try base.setGoal(goal) }

        XCTAssertTrue(JournalImporter.undoGoals(recorded, in: base))
        XCTAssertEqual(try base.goals().map(\.nutrient), ["sodium"])
    }

    /// Rollback keeps the receipt when a goal could not be removed, so the receipt still names it. Fails without the
    /// receipt-kept rule, which deletes the receipt regardless of the removal.
    func testAFailedGoalRemovalKeepsTheReceipt() throws {
        let base = try goalStore()
        let data = try goalsExport([protein, energy])
        let digest = JournalImporter.fileDigest(data)
        var calls = 0
        let store = ScriptedGoalStore(base: base, refusesRemoval: true) { _, _ in
            calls += 1
            if calls == 2 { throw JournalImportError.corrupt("stopped") }
        }
        let restoreJournal = try journal()
        XCTAssertThrowsError(try JournalImporter.importExport(
            data, into: restoreJournal, favorites: nil, goals: store))
        XCTAssertNotNil(try base.goalRestoreReceipt(digest), "a goal is left, so the receipt still names it")
        XCTAssertEqual(try restoreJournal.restoreInProgressDigest(), digest, "a leftover receipt keeps the restore flag set so a resume can finish it")
    }

    /// A goal the restore set, then the person deleted after every goal was written, is not added back when the same
    /// file is imported again while the flag is still set. Fails without the done marker, which makes resume add it.
    func testAGoalDeletedAfterTheGoalsFinishedIsNotReAdded() throws {
        let base = try goalStore()
        let data = try goalsExport([protein, energy])
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try base.recordGoalRestoreReceipt(digest, goals: [
            NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g),
            NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .kcal),
        ])
        try base.markGoalRestoreReceiptDone(digest)
        try base.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        // The person deletes energy after the goals were written.

        XCTAssertThrowsError(try JournalImporter.importExport(data, into: journal, favorites: nil, goals: base))
        XCTAssertNil(try base.goal(for: "energy"), "a goal the person deleted must not come back")
    }

    /// The receipt records the goals missing when the restore planned its writes. A goal the person sets during the
    /// restore, to exactly the value the file carries, is not written by the restore, so a rollback must not remove it.
    /// Fails while rollback removes every recorded goal whose value still matches, written by the restore or not.
    func testAGoalTheUserSetDuringTheRestoreSurvivesRollback() throws {
        let base = try goalStore()
        let sodium = JournalExportGoal(nutrient: "sodium", target: "2300", unit: "mg")
        let data = try goalsExport([protein, energy, sodium])
        var calls = 0
        let store = ScriptedGoalStore(base: base) { _, base in
            calls += 1
            if calls == 1 {
                // The person sets energy to the file's value while the restore writes protein.
                try base.setGoal(NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .kcal))
            } else {
                throw JournalImportError.corrupt("stopped")
            }
        }
        XCTAssertThrowsError(try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: store))
        XCTAssertEqual(try base.goal(for: "energy")?.target, Decimal(2000), "the person's own goal must survive")
        XCTAssertNil(try base.goal(for: "protein"), "the goal the restore wrote is removed")
    }

    /// Every goal the restore writes is one its receipt names. A check inside the write: this passes today, and it
    /// guards against a later change that writes a goal the receipt does not record.
    func testEveryGoalWrittenIsOneTheReceiptNames() throws {
        let base = try goalStore()
        let data = try goalsExport([protein, energy])
        let digest = JournalImporter.fileDigest(data)
        // The person already has an energy goal, so the restore neither records nor writes it.
        try base.setGoal(NutrientGoal(nutrient: "energy", target: Decimal(1500), unit: .kcal))
        let store = ScriptedGoalStore(base: base) { goal, base in
            let recorded = try base.goalRestoreReceipt(digest)?.map(\.nutrient) ?? []
            XCTAssertTrue(recorded.contains(goal.nutrient), "\(goal.nutrient) written but not recorded")
        }
        let summary = try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: store)
        XCTAssertEqual(summary.goals, 1)
        XCTAssertEqual(try base.goal(for: "energy")?.target, Decimal(1500), "an existing goal is never replaced")
    }

    /// A stop after the receipt is recorded and before any goal is written. The person then sets energy, and importing
    /// the same file again must keep it: resume adds only what is absent at that moment. Fails when the existing-goal
    /// guard in addMissingGoals is removed, since the file's energy would then overwrite the person's.
    func testAResumeKeepsAGoalThePersonSetAfterTheStop() throws {
        let base = try goalStore()
        let data = try goalsExport([protein, energy])
        let digest = JournalImporter.fileDigest(data)
        let journal = try journal()
        try journal.markRestoreInProgress(fileDigest: digest)
        try base.recordGoalRestoreReceipt(digest, goals: [
            NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g),
            NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .kcal),
        ])
        try base.setGoal(NutrientGoal(nutrient: "energy", target: Decimal(1800), unit: .kcal))

        _ = try JournalImporter.importExport(data, into: journal, favorites: nil, goals: base)

        XCTAssertEqual(try base.goal(for: "energy")?.target, Decimal(1800), "a goal the person set after the stop is kept")
        XCTAssertEqual(try base.goal(for: "protein")?.target, Decimal(60))
    }

    /// setGoal refuses a key in the receipt namespace and writes nothing: the goals and the receipt are unchanged.
    /// Fails when the prefix guard in setGoal is removed, since the receipt row would then be overwritten.
    func testSetGoalRefusesAReceiptKeyAndWritesNothing() throws {
        let goals = try goalStore()
        try goals.recordGoalRestoreReceipt("digest-a", goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])
        let before = try goals.goals()
        XCTAssertThrowsError(
            try goals.setGoal(NutrientGoal(nutrient: "restore-receipt:digest-a", target: Decimal(1), unit: .g))
        ) { error in
            XCTAssertEqual(error as? GoalStoreError, .unknownNutrient)
        }
        XCTAssertEqual(try goals.goals(), before, "a refused write changes no goal")
        XCTAssertEqual(
            try goals.goalRestoreReceipt("digest-a")?.map(\.nutrient), ["protein"], "the receipt is unchanged"
        )
    }

    /// A fresh restore that succeeds leaves no receipt behind. A receipt left after a fresh restore would make the next
    /// import of the same file look like a resume.
    func testAFreshRestoreLeavesNoReceiptBehind() throws {
        let base = try goalStore()
        let data = try goalsExport([protein, energy])
        let summary = try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: base)
        XCTAssertEqual(summary.goals, 2)
        XCTAssertNil(
            try base.goalRestoreReceipt(JournalImporter.fileDigest(data)),
            "a finished fresh restore removes its receipt"
        )
    }

    /// A goal named with the receipt prefix would be hidden from every read, so the file is refused instead.
    func testAGoalNamedLikeAReceiptIsRefused() throws {
        let data = try goalsExport([JournalExportGoal(nutrient: "restore-receipt:x", target: "1", unit: "g")])
        XCTAssertThrowsError(
            try JournalImporter.importExport(data, into: try journal(), favorites: nil, goals: try goalStore())
        )
    }

    /// After a rollback that left a goal behind, importing the same file again resumes it: it finishes without an
    /// error, adds only the goal that is still missing, and does not duplicate the goal that was left.
    func testAResumeAfterAFailedRollbackFinishesWithoutDuplicates() throws {
        let base = try goalStore()
        let data = try goalsExport([protein, energy])
        var calls = 0
        let refusing = ScriptedGoalStore(base: base, refusesRemoval: true) { _, _ in
            calls += 1
            if calls == 2 { throw JournalImportError.corrupt("stopped") }
        }
        let restoreJournal = try journal()
        XCTAssertThrowsError(try JournalImporter.importExport(data, into: restoreJournal, favorites: nil, goals: refusing))

        let summary = try JournalImporter.importExport(data, into: restoreJournal, favorites: nil, goals: base)

        XCTAssertEqual(summary.goals, 1, "only the goal still missing is added")
        XCTAssertEqual(try base.goal(for: "protein")?.target, Decimal(60))
        XCTAssertEqual(try base.goal(for: "energy")?.target, Decimal(2000))
        XCTAssertEqual(try base.goals().count, 2, "no goal is duplicated")
        XCTAssertNil(try restoreJournal.restoreInProgressDigest(), "the finished resume clears its flag")
    }

    func testAVersion7FileHasNoGoalsAndStillImports() throws {
        let goals = try goalStore()
        let summary = try JournalImporter.importExport(
            try goalsExport([], schemaVersion: 7), into: try journal(), favorites: nil, goals: goals)
        XCTAssertEqual(summary.goals, 0)
        XCTAssertTrue(try goals.goals().isEmpty)
    }
    /// A goal read that fails during the rollback leaves that goal behind: the restore reports partial, and the receipt and
    /// the flag stay for a resume. Fails when an unreadable goal is taken as one this run did not write, since the rollback
    /// then says nothing remains and clears the flag.
    func testAGoalReadThatFailsDuringTheRollbackKeepsTheReceiptAndFlag() throws {
        let directory = try self.directory()
        let base = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        addTeardownBlock { base.close() }
        let data = try exportData(favorites: false)
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["goals"] = [
            ["nutrient": "protein", "target": "60", "unit": "g"],
            ["nutrient": "energy", "target": "2000", "unit": "kcal"],
        ]
        let file = try JSONSerialization.data(withJSONObject: root)
        let journal = try store(directory)
        final class Holder { var store: ScriptedGoalStore? }
        let holder = Holder()
        var calls = 0
        let scripted = ScriptedGoalStore(base: base) { _, _ in
            calls += 1
            if calls == 2 {
                holder.store?.failsRead = true
                throw JournalImportError.corrupt("stopped")
            }
        }
        holder.store = scripted

        XCTAssertThrowsError(try JournalImporter.importExport(file, into: journal, favorites: nil, goals: scripted)) {
            guard case .partialRestore = $0 as? JournalImportError else { return XCTFail("expected a partial restore, got \($0)") }
        }
        XCTAssertNotNil(try base.goalRestoreReceipt(JournalImporter.fileDigest(file)), "the receipt stays for the resume")
        XCTAssertNotNil(try journal.restoreInProgressDigest(), "the flag is kept while a goal may remain")
    }

    /// A receipt that cannot be removed after a rollback keeps the restore flag, so a resume can still finish or clear it.
    /// Fails when the receipt removal is swallowed and the flag is cleared over the receipt.
    func testAReceiptThatCannotBeRemovedAfterARollbackKeepsTheFlag() throws {
        let directory = try self.directory()
        let base = try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
        addTeardownBlock { base.close() }
        let data = try exportData(favorites: false)
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["goals"] = [["nutrient": "protein", "target": "60", "unit": "g"]]
        let file = try JSONSerialization.data(withJSONObject: root)
        let journal = try store(directory)
        var calls = 0
        let scripted = ScriptedGoalStore(base: base) { _, _ in
            calls += 1
            if calls == 1 { throw JournalImportError.corrupt("stopped") }
        }
        scripted.failsReceiptRemoval = true

        XCTAssertThrowsError(try JournalImporter.importExport(file, into: journal, favorites: nil, goals: scripted)) {
            guard case .partialRestore = $0 as? JournalImportError else { return XCTFail("expected a partial restore, got \($0)") }
        }
        XCTAssertNotNil(try journal.restoreInProgressDigest(), "the flag is kept while the receipt remains")
    }
}
