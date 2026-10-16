import Foundation
import NutritionJournal

/// What logging a saved meal wrote: the entries it created, which Undo removes exactly, and how many items
/// it could not log.
public struct SavedMealLogResult: Equatable, Sendable {
    public let createdIDs: [String]
    /// Items left out because their amounts no longer read back or their saved product is gone.
    public let skippedCount: Int

    public init(createdIDs: [String], skippedCount: Int) {
        self.createdIDs = createdIDs
        self.skippedCount = skippedCount
    }

    public var loggedCount: Int { createdIDs.count }
}

/// Why undoing a logged meal stopped short. The ids are the entries still in the journal.
public enum SavedMealUndoError: Error, Equatable, Sendable {
    case incomplete(remainingIDs: [String])
}

/// A write failed while logging a meal and the entries already created could not all be deleted again.
/// `remainingIDs` are the entries still in the journal, so a screen can offer to remove them with Undo
/// rather than leave part of the meal logged unseen; `underlying` is the write failure itself.
public struct SavedMealPartialLogError: Error {
    public let remainingIDs: [String]
    public let underlying: any Error

    public init(remainingIDs: [String], underlying: any Error) {
        self.remainingIDs = remainingIDs
        self.underlying = underlying
    }

    public var result: SavedMealLogResult { SavedMealLogResult(createdIDs: remainingIDs, skippedCount: 0) }
}

/// Logs a saved meal as ordinary new entries: one `create` per item, all at `now`, under one meal.
///
/// Each entry is like any other entry, so it is written to Apple Health once that is connected.
public struct SavedMealLogger {
    private let store: JournalStore
    private let repeater: IntakeRepeater

    public init(
        store: JournalStore, timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.repeater = IntakeRepeater(
            store: store, timeZoneProvider: IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider),
            makeID: makeID)
    }

    /// Logs every item of `saved` under `meal` (nil logs them with no meal), in the order they were saved.
    ///
    /// An item that cannot be logged as it was saved (an amount that no longer reads back, or a saved product
    /// that is gone) is skipped and counted, and the rest are logged. Any other store failure leaves no
    /// entry behind: the entries this call already created are deleted again before the error is rethrown,
    /// so a meal is never left half logged by a failed write. If one of those deletes fails too, the error
    /// is a `SavedMealPartialLogError` naming the entries still in the journal.
    public func log(_ saved: SavedMeal, as meal: MealLabel?, now: Date) throws -> SavedMealLogResult {
        var created: [String] = []
        var skipped = 0
        let loggedUnitIndex = LoggedUnitIndex.load(from: store)
        for item in saved.items {
            guard var template = RepeatTemplate(favorite: item, loggedUnitIndex: loggedUnitIndex),
                !template.components.isEmpty
            else {
                skipped += 1
                continue
            }
            template.meal = meal?.rawValue
            do {
                created.append(try repeater.create(from: template, now: now))
            } catch IntakeRepeatError.productUnavailable {
                skipped += 1
            } catch let writeError {
                var remaining: [String] = []
                for id in created.reversed() {
                    do {
                        try store.delete(intakeID: id, now: now)
                    } catch JournalError.intakeDeleted(_) {
                        continue
                    } catch {
                        remaining.append(id)
                    }
                }
                guard remaining.isEmpty else {
                    throw SavedMealPartialLogError(remainingIDs: Array(remaining.reversed()), underlying: writeError)
                }
                throw writeError
            }
        }
        return SavedMealLogResult(createdIDs: created, skippedCount: skipped)
    }

    /// Deletes exactly the entries `result` created. An entry already deleted counts as undone. When any
    /// other delete fails, every remaining entry is still tried, and the ones left are reported.
    public func undo(_ result: SavedMealLogResult, now: Date) throws {
        var remaining: [String] = []
        for id in result.createdIDs {
            do {
                try store.delete(intakeID: id, now: now)
            } catch JournalError.intakeDeleted(_) {
                continue
            } catch {
                remaining.append(id)
            }
        }
        guard remaining.isEmpty else { throw SavedMealUndoError.incomplete(remainingIDs: remaining) }
    }
}
