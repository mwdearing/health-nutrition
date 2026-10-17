import Foundation
import NutritionJournal

/// What the last logged saved meal wrote, for the Undo offer: exactly those entries, and the words shown.
public struct SavedMealUndoToken: Equatable {
    /// New for every offer, so the screen's ten-second window restarts even when two offers name the same entries.
    public let id = UUID()
    public let result: SavedMealLogResult
    public let message: String
}

/// The saved meals screens share: the list, saving a Journal meal, logging one and undoing it.
///
/// It keeps what it last read. The app reads it again after Erase all data and after a journal restore (which
/// can write saved meals from export version 4), and each screen that lists saved meals reads it again as it
/// appears, so a list another window changed is not shown stale.
@MainActor
public final class SavedMealsModel: ObservableObject {
    /// Newest first.
    @Published public private(set) var meals: [SavedMeal] = []
    /// Set when the list cannot be read. The list is then empty, never what an earlier read showed.
    @Published public private(set) var loadError: String?
    /// The outcome of the last save, removal or failed log, for the screen that ran it; nil when there is none.
    @Published public private(set) var notice: String?
    /// True when `notice` reports a refusal or a failure.
    @Published public private(set) var noticeIsFailure = false
    /// The entries the last log wrote, while Undo is offered.
    @Published public private(set) var undoToken: SavedMealUndoToken?
    /// Set while entries a failed log or a failed Undo left behind are still in the journal. Unlike `notice` it
    /// is not dropped by a later action or read: it goes only when those entries are gone, removed by Undo,
    /// in the Journal or by an erase. It is kept in memory, so it lasts while the app runs; the entries
    /// themselves are ordinary Journal entries and stay visible there.
    @Published public private(set) var leftoverWarning: String?
    private var leftoverIDs: [String] = []

    private let book: SavedMealBook
    private let logger: SavedMealLogger
    private let journal: JournalStore

    public init(
        store: any SavedMealStoring, journal: JournalStore, timeZoneIdentifier: String? = nil,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.book = SavedMealBook(store: store, makeID: makeID)
        self.logger = SavedMealLogger(store: journal, timeZoneIdentifier: timeZoneIdentifier, makeID: makeID)
        self.journal = journal
    }

    /// Reads the list again. Any earlier notice goes with it: a notice belongs to the action that set it, and
    /// each action that sets one reloads first, so a screen opened later never shows another screen's notice.
    public func load() {
        notice = nil
        noticeIsFailure = false
        do {
            meals = try book.meals()
            loadError = nil
        } catch {
            meals = []
            loadError = SavedMealError.unreadable.message
        }
        refreshLeftovers()
    }

    /// The meals whose name contains `query`, ignoring case and outer spaces; every meal for an empty query.
    public func matching(_ query: String) -> [SavedMeal] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return meals }
        return meals.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    /// Saves `intakes` as one meal, in the order they were eaten. When any entry cannot be read the meal is
    /// not saved at all: a meal missing an item would log less than was eaten without saying so.
    @discardableResult
    public func save(name: String, meal: MealLabel?, intakes: [Intake]) -> Bool {
        let provider = RecentItemsProvider(store: journal)
        // The templates below read which entries were kept out of Library; a failed read refuses the save rather
        // than building them as if none were.
        // The units are read the same way: a failed read refuses the save, so a meal is never built without them.
        do {
            try provider.requireExclusions()
            _ = try LoggedUnitIndex.loadOrThrow(from: journal)
        } catch { return finish(failure: "Could not save the meal.") }
        var templates: [RepeatTemplate] = []
        // Entries logged at the same moment, as a copied day's are, keep the order Copy to today uses.
        for intake in intakes.sorted(by: { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }) {
            guard let revisions = try? journal.revisions(of: intake.id),
                let current = revisions.first(where: { $0.number == intake.currentRevision })
            else {
                return finish(failure: "One of these entries can't be read, so the meal was not saved.")
            }
            templates.append(provider.template(intake: intake, revision: current))
        }
        do {
            let saved = try book.add(name: name, meal: meal, templates: templates)
            // The units the entries were logged in follow each item, keyed by the item's own id.
            // A unit that cannot be written takes the meal back out, so it never saves without its units.
            if let units = journal as? JournalLoggedUnits {
                var writtenOwners: [(owner: String, component: String)] = []
                do {
                    for (item, template) in zip(saved.items, templates) {
                        for component in template.components where component.unit == .mL {
                            guard let loggedUnit = template.loggedUnits[component.componentID] else { continue }
                            try units.recordLoggedUnit(JournalLoggedUnit(
                                intakeID: item.id, componentID: component.componentID, unit: loggedUnit))
                            writtenOwners.append((item.id, component.componentID))
                        }
                    }
                } catch {
                    // The rows written so far go with the meal. A removal that fails leaves a row for an id no meal
                    // has any more, which nothing reads and which a restore or erase clears.
                    for written in writtenOwners {
                        try? units.removeLoggedUnit(intakeID: written.owner, componentID: written.component)
                    }
                    do {
                        try book.remove(id: saved.id)
                    } catch {
                        // The meal could not be taken back out, so it is saved, only without its units. It is a save
                        // that happened, so this returns true and the Journal's sheet closes; the notice says what
                        // was lost.
                        load()
                        notice = Self.savedWithoutUnitsMessage
                        noticeIsFailure = true
                        return true
                    }
                    return finish(failure: "Could not save the meal.")
                }
            }
            load()
            notice = "Saved \(saved.name). Log it again from Add, in Find products."
            noticeIsFailure = false
            return true
        } catch let error as SavedMealError {
            return finish(failure: error.message)
        } catch {
            return finish(failure: "Could not save the meal.")
        }
    }

    /// Logs `saved` now under `meal` (nil logs it with no meal) and offers Undo for exactly what it wrote.
    @discardableResult
    public func log(_ saved: SavedMeal, as meal: MealLabel?, now: Date) -> Bool {
        // An earlier offer is dropped first, so Undo only ever names the meal just logged.
        undoToken = nil
        do {
            let result = try logger.log(saved, as: meal, now: now)
            guard result.loggedCount > 0 else {
                return finish(failure: "Nothing was logged: \(Self.itemsText(result.skippedCount)) can no longer be logged.")
            }
            let total = result.loggedCount + result.skippedCount
            let message = result.skippedCount == 0
                ? "Logged \(saved.name)."
                : "Logged \(result.loggedCount) of \(total) items of \(saved.name). \(Self.itemsText(result.skippedCount)) can no longer be logged."
            undoToken = SavedMealUndoToken(result: result, message: message)
            notice = nil
            noticeIsFailure = false
            return true
        } catch let partial as SavedMealPartialLogError {
            // The write failed and so did its cleanup. The leftovers are kept as a warning, not only on the
            // timed Undo offer, so a meal left half logged is never reported for just ten seconds.
            let message = "Could not log \(saved.name). \(Self.entriesText(partial.remainingIDs.count)) "
                + (partial.remainingIDs.count == 1 ? "was" : "were") + " left in the journal."
            undoToken = SavedMealUndoToken(result: partial.result, message: message)
            addLeftovers(partial.remainingIDs)
            notice = nil
            noticeIsFailure = false
            return false
        } catch {
            return finish(failure: "Could not log \(saved.name). Nothing was logged.")
        }
    }

    /// Deletes exactly the entries the offer names. False, keeping an offer for what is left, when it fails.
    @discardableResult
    public func undo(now: Date) -> Bool {
        guard let token = undoToken else { return false }
        do {
            try logger.undo(token.result, now: now)
            undoToken = nil
            refreshLeftovers()
            return true
        } catch SavedMealUndoError.incomplete(let remaining) {
            undoToken = SavedMealUndoToken(
                result: SavedMealLogResult(createdIDs: remaining, skippedCount: 0),
                message: "Could not remove \(Self.entriesText(remaining.count)). Try again.")
            addLeftovers(remaining)
            return false
        } catch {
            return false
        }
    }

    /// Ends the Undo window, but only if `token` is still the current offer.
    public func expireUndo(_ token: SavedMealUndoToken) {
        if undoToken == token { undoToken = nil }
    }

    /// Drops any Undo offer, for when the screen showing it goes away.
    public func clearUndo() {
        undoToken = nil
    }

    public func remove(_ saved: SavedMeal) {
        do {
            try book.remove(id: saved.id)
            load()
            notice = nil
            noticeIsFailure = false
        } catch let error as SavedMealError {
            finish(failure: error.message)
        } catch {
            finish(failure: "Could not remove the saved meal.")
        }
    }

    /// The meals to offer when logging `saved`: the one it was saved with first, then the others, then none.
    nonisolated public static func mealChoices(for saved: SavedMeal) -> [MealLabel?] {
        let others: [MealLabel?] = MealLabel.allCases.filter { $0 != saved.meal }.map { Optional($0) }
        guard let first = saved.meal else { return others + [nil] }
        return [Optional(first)] + others + [nil]
    }

    /// Warns about entries a failed log elsewhere (a shortcut) could not remove again, as a failed log here does.
    public func recordLeftovers(_ ids: [String]) {
        addLeftovers(ids)
    }

    private func addLeftovers(_ ids: [String]) {
        leftoverIDs += ids.filter { !leftoverIDs.contains($0) }
        refreshLeftovers()
    }

    /// Keeps only the leftovers still in the journal, and words the warning for them. When the journal
    /// cannot be read the leftovers are kept, since they may still be there.
    private func refreshLeftovers() {
        if !leftoverIDs.isEmpty, let active = try? Set(journal.activeIntakes().map(\.id)) {
            leftoverIDs = leftoverIDs.filter { active.contains($0) }
        }
        let count = leftoverIDs.count
        leftoverWarning = count == 0 ? nil
            : "\(Self.entriesText(count)) left over from logging or undoing a saved meal "
                + (count == 1 ? "is" : "are") + " still in the Journal. Delete "
                + (count == 1 ? "it" : "them") + " there."
    }

    static let savedWithoutUnitsMessage = "The meal was saved, but the units you entered could not be kept."

    /// Reloads first and sets the message after, so the reload can never clear the reason it gives.
    @discardableResult
    private func finish(failure message: String) -> Bool {
        load()
        notice = message
        noticeIsFailure = true
        return false
    }

    nonisolated static func itemsText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    nonisolated static func entriesText(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }
}
