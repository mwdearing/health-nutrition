import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

public struct EntryComponentRow: Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Exact decimal text, or "unknown".
    public let amountText: String
    public let unit: MeasureUnit

    public init(id: String, name: String, amountText: String, unit: MeasureUnit) {
        self.id = id
        self.name = name
        self.amountText = amountText
        self.unit = unit
    }
}

/// One compound the entry's product snapshot states under a name the fifteen journal nutrients do not,
/// as the entry screen shows it. A captured supplement panel stores these under a slug of the printed
/// name, so the slug is spelled back out for the reader.
public struct EntryNutrientRow: Equatable, Identifiable {
    public let key: String
    public let name: String
    /// The amount with its unit, or a word for a value that states no amount. An adds row is what the entry
    /// added, rounded as Today rounds a total; a row of all values is the label's own figure, exactly.
    public let amountText: String

    public var id: String { key }

    public init(key: String, name: String, amountText: String) {
        self.key = key
        self.name = name
        self.amountText = amountText
    }
}

public struct EntryRevisionRow: Equatable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let createdAt: Date
    public let changeReason: String
}

/// One change to the entry, newest first in `changes`: the revision's number, what changed in plain
/// words, when it was written, and the reason the person gave when they gave one.
public struct EntryChangeRow: Equatable, Identifiable {
    public let id: Int
    public let verb: String
    public let at: Date
    public let note: String?

    public init(id: Int, verb: String, at: Date, note: String?) {
        self.id = id
        self.verb = verb
        self.at = at
        self.note = note
    }
}

public struct EntryDestinationRow: Equatable, Identifiable {
    public var id: String { destination.rawValue }
    public let destination: JournalDestination
    public let label: String
    /// State as words, so color is never the only signal.
    public let stateText: String
    public let iconName: String
    /// The destination's name as a person reads it, e.g. "Apple Health".
    public let sentToLabel: String
    /// The state as a phrase under "Sent to", e.g. "Waiting to send".
    public let sentToText: String
    /// The destination's state as a value, so a reader compares states rather than their words.
    public let state: DestinationState
    /// Why the delivery needs a person, as the delivery recorded it. Nil unless the state is needs attention
    /// and a reason was recorded.
    public var attentionReason: String? = nil
}

/// One choice on the entry screen's Meal menu: a named meal, or nil for "Not set".
public struct MealOption: Equatable, Identifiable {
    public let meal: MealLabel?

    public var id: String { meal?.rawValue ?? "not-set" }
    public var title: String { meal?.displayName ?? "Not set" }
}

/// One edited component: the amount arrives as text and is parsed with the POSIX parser.
public struct EditedComponent: Equatable {
    public var componentID: String
    public var name: String
    public var amountText: String
    public var unit: MeasureUnit

    public init(componentID: String, name: String, amountText: String, unit: MeasureUnit) {
        self.componentID = componentID
        self.name = name
        self.amountText = amountText
        self.unit = unit
    }
}

/// One row under "Where this came from": what the entry's values were entered as, or a fact the product
/// snapshot stores about them, with the value as the snapshot states it.
public struct SourceDetailRow: Identifiable, Equatable {
    public let label: String
    public let value: String

    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

@MainActor
public final class EntryDetailViewModel: ObservableObject {
    /// Shown when the entry has a newer revision than the one this screen loaded.
    static let changedSinceOpenedNotice = "This entry changed since you opened it. Reopen it to see the latest amounts."

    /// The reason a revision carries when the person did not write one.
    public static let defaultChangeReason = "Edited"
    /// What a correction of the entry's time alone is recorded as, because a history that reads
    /// "Edited" for a change of time tells a reader nothing about what happened.
    public static let timeCorrectionReason = "Time corrected"
    /// What a change of the meal alone is recorded as, so the Changes list names it rather than "Changed".
    public static let mealChangedReason = "Meal changed"
    /// The choices the Meal menu offers: each named meal in order, then "Not set".
    public static let mealOptions: [MealOption] = MealLabel.allCases.map { MealOption(meal: $0) }
        + [MealOption(meal: nil)]
    /// The reason revision 1 is stored with, when the entry is first logged.
    static let creationReason = "created"

    @Published public private(set) var components: [EntryComponentRow] = []
    /// The compounds the product snapshot states under names the fifteen journal nutrients do not, so a
    /// scanned supplement's own rows are visible where the entry's amounts are shown.
    @Published public private(set) var additionalNutrients: [EntryNutrientRow] = []
    /// "This entry adds": the snapshot's standard values scaled to the amount this entry logged.
    @Published public private(set) var adds: [EntryNutrientRow] = []
    /// Every nutrient the snapshot states with a known value, unscaled, as the label printed them.
    @Published public private(set) var allValues: [EntryNutrientRow] = []
    /// Where the entry's values came from, as one line.
    @Published public private(set) var sourceLine: String = EntryDetailViewModel.sourceLine(for: nil)
    /// The rows under "Where this came from": the input, and what the snapshot stores about the values.
    @Published public private(set) var sourceDetailRows: [SourceDetailRow] = EntryDetailViewModel.sourceDetails(for: nil)
    /// The product's name and brand, and what kind of thing it is, for the header. Nil when there is no snapshot.
    @Published public private(set) var productName: String?
    @Published public private(set) var brand: String?
    @Published public private(set) var kind: ProductKind = .food
    /// A drink's water share, 0 to 100, as the edit screen shows it. Nil means the stored share is kept.
    @Published public var waterSharePercent: Decimal? = nil
    /// The share the entry states when it loads, so a share changed alone counts as an unsaved change.
    private var loadedWaterSharePercent: Decimal? = nil
    /// The entry's changes, newest first.
    @Published public private(set) var changes: [EntryChangeRow] = []
    @Published public private(set) var revisions: [EntryRevisionRow] = []
    @Published public private(set) var destinations: [EntryDestinationRow] = []
    /// The parked operations behind each destination that needs attention, oldest revision first. These are
    /// what "Try again" re-arms.
    private var parkedOperations: [JournalDestination: [(operationID: String, revision: Int)]] = [:]
    @Published public private(set) var currentRevision: Int = 0
    @Published public private(set) var fieldErrors: [String: String] = [:]
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isDeleted = false
    /// Edit drafts by component id, bound to the text fields.
    ///
    /// Editing a field drops the message a refused save left on it. The message describes the text that
    /// was refused, and typing the loaded amount back removes Save, so nothing else could clear it.
    @Published public var drafts: [String: String] = [:] {
        didSet {
            let edited = fieldErrors.keys.filter { drafts[$0] != oldValue[$0] }
            guard !edited.isEmpty else { return }
            for id in edited { fieldErrors[id] = nil }
        }
    }
    @Published public var changeReason: String = EntryDetailViewModel.defaultChangeReason
    /// The entry's time as an editable draft, which the "When" row binds to. `load` seeds it from
    /// the stored value, and a save writes a correction only once it differs from it.
    @Published public var occurredAt: Date
    /// The meal the entry states, as words, or nil when it states none.
    @Published public private(set) var mealText: String?
    /// The named meal the entry states, which is what the Meal menu shows as chosen. Nil for "Not set" and
    /// for a meal this build does not name.
    @Published public private(set) var selectedMeal: MealLabel?
    /// Whether the Meal menu can be used: the entry states no meal, or one of the named meals, and no amount or
    /// time edit is waiting to be saved (choosing a meal reloads the screen). A meal this build does not name
    /// (an imported free-text value) is shown as written and is left as it is.
    public var canChangeMeal: Bool { (mealText == nil || selectedMeal != nil) && !isDirty }

    /// Log again copies the stored entry, so it is offered only when no edit is waiting to be saved: then the copy
    /// matches what the sheet shows. With unsaved edits the person saves first.
    public var canLogAgain: Bool { !isDirty }
    /// The time exactly as the journal holds it, and nil until `load` has read the entry. A draft
    /// may only correct that, so a save made before the first load cannot move an entry whose
    /// stored time this model has not seen.
    private var storedOccurredAt: Date?
    /// The amount drafts as `load` seeded them, so `isDirty` compares what the person has typed with
    /// what the entry states.
    private var loadedDrafts: [String: String] = [:]
    /// The unit each component was logged in, read when the entry loads. Only a supplement reads back in it.
    private var loggedUnits: [String: MeasureUnit] = [:]
    /// The zone the entry's time is a wall clock in, as the view shows and edits it.
    ///
    /// The picker is bound to this rather than to the device zone, because the stored time is a wall
    /// clock in **this** zone: showing it in the device's zone would display a different time of day from
    /// the one the entry states, and a person correcting an entry would be editing the wrong reading. A
    /// stored identifier the platform no longer resolves falls back to the current zone, so the picker
    /// still reads rather than being given a zone that does not exist.
    public var storedTimeZone: TimeZone {
        guard let timeZoneIdentifier else { return .current }
        return TimeZone(identifier: timeZoneIdentifier) ?? .current
    }
    private var timeZoneIdentifier: String?

    public let intakeID: String
    private let store: JournalStore
    private let repeater: IntakeRepeater
    /// Read on each load, so a preference changed on another screen is honored here too.
    private let preferences: DisplayPreferences

    /// The unit system the displayed amounts are shown in.
    public var unitSystem: UnitSystem { preferences.unitSystem }

    public init(
        store: JournalStore,
        intakeID: String,
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
        preferences: DisplayPreferences = InMemoryDisplayPreferences()
    ) {
        self.store = store
        self.intakeID = intakeID
        self.preferences = preferences
        self.occurredAt = Date()
        self.repeater = IntakeRepeater(
            store: store, timeZoneProvider: IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider),
            makeID: makeID)
    }

    public func load(now: Date) {
        do {
            additionalNutrients = []
            guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }) else {
                isDeleted = true
                errorMessage = "This entry is no longer available."
                return
            }
            let all = try store.revisions(of: intakeID).sorted { $0.number < $1.number }
            guard let current = all.first(where: { $0.number == intake.currentRevision }) else {
                errorMessage = "Could not read this entry."
                return
            }
            currentRevision = current.number
            components = current.components.map {
                EntryComponentRow(
                    id: $0.componentID, name: AmountText.name($0),
                    amountText: $0.amount.isNaN ? "unknown" : DecimalFormatting.text($0.amount), unit: $0.unit)
            }
            let snapshot = current.productSnapshotID.flatMap { try? store.product(snapshotID: $0) }
            additionalNutrients = Self.additionalNutrients(of: snapshot)
            sourceLine = Self.sourceLine(for: snapshot)
            sourceDetailRows = Self.sourceDetails(for: snapshot)
            productName = snapshot?.name
            brand = snapshot?.brand
            kind = ProductKindResolution.kind(
                snapshotID: current.productSnapshotID, snapshotKind: { _ in snapshot?.kind }, category: intake.category)
            waterSharePercent = current.components.compactMap(\.hydrationPercent).first
            loadedWaterSharePercent = waterSharePercent
            loggedUnits = try LoggedUnitIndex.loadOrThrow(from: store)[intakeID] ?? [:]
            allValues = Self.allValues(of: snapshot)
            adds = Self.adds(of: snapshot, logged: current.components)
            // The field reads at the digits a reading carries (354.9 mL, not 354.88235475 mL). Untouched, a
            // save still carries the stored component, so the exact figure stays behind the text.
            drafts = Dictionary(uniqueKeysWithValues: current.components.map {
                ($0.componentID, Self.seededAmountText($0.amount, unit: $0.unit))
            })
            loadedDrafts = drafts
            occurredAt = intake.occurredAt
            storedOccurredAt = intake.occurredAt
            timeZoneIdentifier = intake.timeZoneIdentifier
            mealText = MealLabel.displayName(for: intake.meal)
            selectedMeal = intake.meal.flatMap {
                MealLabel(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            revisions = all.reversed().map {
                EntryRevisionRow(number: $0.number, createdAt: $0.createdAt, changeReason: $0.changeReason)
            }
            changes = Self.changeRows(of: all)
            let projections = try store.projections(of: intakeID).filter { $0.isCurrent }
            parkedOperations = try Self.parkedOperations(of: intakeID, in: store)
            let suspension = store as? JournalDeliverySuspension
            let parked = parkedOperations
            destinations = projections.sorted { $0.destination.rawValue < $1.destination.rawValue }.map {
                projection -> EntryDestinationRow in
                // The oldest parked operation is the one holding the entry back, so its reason is the one shown.
                // The reason of the operation for the revision on screen, when that one is parked; otherwise the
                // oldest parked one, which is what holds the later revisions back.
                var reason: String?
                if projection.state == .needsAttention, let operations = parked[projection.destination],
                   let shown = operations.first(where: { $0.revision == projection.revision }) ?? operations.first {
                    reason = (try? suspension?.suspensionReason(operationID: shown.operationID)) ?? nil
                }
                return EntryDestinationRow(
                    destination: projection.destination, label: Self.label(projection.destination),
                    stateText: Self.stateText(projection.state), iconName: Self.icon(projection.state),
                    sentToLabel: Self.sentToLabel(projection.destination),
                    sentToText: Self.sentToText(projection.state), state: projection.state,
                    attentionReason: reason)
            }
            fieldErrors = [:]
            errorMessage = nil
            changeReason = EntryDetailViewModel.defaultChangeReason
        } catch {
            errorMessage = "Could not read this entry."
        }
    }

    /// Whether "Try again" has anything to re-arm for this destination: a delivery of this entry that was
    /// parked for a person and is still queued.
    public func canRetry(_ row: EntryDestinationRow) -> Bool {
        row.state == .needsAttention && !(parkedOperations[row.destination] ?? []).isEmpty
    }

    /// Re-arms every parked delivery of this entry to one destination, so the next delivery pass tries it
    /// again (#103). Re-arming is a person's decision that the cause is resolved, which is why it is a button
    /// and never something a pass does on its own. It enables nothing: a destination that is off stays off.
    ///
    /// Every parked revision is re-armed, older ones included: an older parked revision holds the newer ones
    /// back, and the worker acknowledges one as superseded when a newer one replaces it. A pass already running
    /// read these operations as suspended and writes nothing for them, so a re-arm under it changes nothing that
    /// pass does; the host starts a new pass afterwards (`onRetried` on the view), which delivers them.
    public func retry(_ row: EntryDestinationRow, now: Date = Date()) {
        guard let operations = parkedOperations[row.destination], !operations.isEmpty,
              let outbox = store as? JournalOutboxDelivery else { return }
        do {
            for operation in operations {
                try outbox.rearmDelivery(operationID: operation.operationID)
            }
        } catch {
            load(now: now)
            errorMessage = "Could not try again."
            return
        }
        load(now: now)
    }

    /// The queued, parked operations of one entry by destination, oldest revision first.
    private static func parkedOperations(
        of intakeID: String, in store: JournalStore
    ) throws -> [JournalDestination: [(operationID: String, revision: Int)]] {
        guard let outbox = store as? JournalOutboxDelivery else { return [:] }
        let suspended = try outbox.suspendedOperationIDs()
        guard !suspended.isEmpty else { return [:] }
        let parked = try store.pendingOutbox()
            .filter { $0.intakeID == intakeID && suspended.contains($0.operationID) }
            .sorted { $0.revision < $1.revision }
        return Dictionary(grouping: parked, by: \.destination).mapValues { group in
            group.map { (operationID: $0.operationID, revision: $0.revision) }
        }
    }

    /// Whether the screen holds a change the person has not saved: an amount draft that differs from
    /// the one the entry states, or a time that differs from the stored one. Save is offered only then.
    public var isDirty: Bool {
        if kind == .drink, waterSharePercent != loadedWaterSharePercent { return true }
        for id in Set(drafts.keys).union(loadedDrafts.keys)
        where !Self.sameAmountText(loadedDrafts[id] ?? "", drafts[id] ?? "") {
            return true
        }
        guard let storedOccurredAt else { return false }
        return occurredAt != storedOccurredAt
    }

    /// Whether Close must ask first: unsaved changes would be lost by closing the entry.
    public var closeAsksFirst: Bool { isDirty }

    /// Whether two amount texts state the same amount. Both are trimmed; when both parse, the decimals
    /// decide, so "40.0" and " 40 " match a stored 40. Otherwise the trimmed text decides. The loaded text
    /// is stored text and takes a point only; the draft is typed, so the region's comma is read in it.
    static func sameAmountText(
        _ loaded: String, _ draft: String, decimalSeparator: String? = Locale.current.decimalSeparator
    ) -> Bool {
        let first = loaded.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = AmountParser.parse(first),
            let b = AmountParser.parseTyped(second, decimalSeparator: decimalSeparator)
        { return a == b }
        return first == second
    }

    /// The same amount in the unit the reader chose, recomputed from what is in the text field rather
    /// than left at the value that was loaded, so the line under the field follows the edit being made.
    ///
    /// Nil when there is nothing to show: an amount stored as unknown has no figure to convert, and a
    /// draft that is empty or not yet a number has none either. The line is then hidden rather than
    /// showing a converted "NaN" or a stale figure.
    public func convertedText(for componentID: String) -> String? {
        guard let row = components.first(where: { $0.id == componentID }),
              row.amountText != "unknown",
              let draft = drafts[componentID], let typed = AmountParser.parseTyped(draft)
        else { return nil }
        // An untouched draft is the stored amount, so it converts from the exact figure the Journal converts,
        // not from the rounded text the field was seeded with.
        let untouched = Self.sameAmountText(loadedDrafts[componentID] ?? "", draft)
        let amount = untouched ? (AmountParser.parse(row.amountText) ?? typed) : typed
        // A supplement logged by the spoon reads back in that spoon, so the line never shows fluid ounces for it.
        if kind == .supplement, row.unit == .mL, let logged = loggedUnits[componentID],
            let reading = AmountDisplay.reading(milliliters: amount, loggedAs: logged)
        {
            return reading.text
        }
        // An entry from before units were recorded reads as the spoon its milliliters can only have been typed in.
        if kind == .supplement, row.unit == .mL, loggedUnits[componentID] == nil,
            let legacy = AmountDisplay.legacySpoonReading(milliliters: amount)
        {
            return legacy.text
        }
        return AmountDisplay.display(amount, unit: row.unit, system: preferences.unitSystem, roundsStoredUnit: true).text
    }

    /// Whether the editor offers the water-share stepper: a drink, or an entry with no product record, with a volume amount (#462).
    public var showsWaterShare: Bool {
        (kind == .drink || productName == nil) && components.contains(where: { $0.unit.dimension == .volume })
    }

    /// Writes one new revision with exactly one `edit` call. Invalid amounts write nothing.
    ///
    /// A draft time that differs from the stored one is a correction of when the entry was eaten,
    /// and goes through the same call as an amount: one new revision, the previous one kept. The
    /// zone is the entry's own, so the day it lands on is read the same way as before.
    @discardableResult
    public func save(components edited: [EditedComponent], changeReason reason: String, now: Date) -> Bool {
        do {
            guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }) else {
                fieldErrors = [:]
                errorMessage = "This entry is no longer available."
                return false
            }
            // The drafts were typed against the revision this screen loaded. If another write has made a newer one
            // since, saving would overwrite it without the person having seen it, so the save stops here instead.
            // Revision numbers start at 1, so 0 means no load has happened and there is no screen state to check.
            guard currentRevision == 0 || intake.currentRevision == currentRevision else {
                fieldErrors = [:]
                errorMessage = Self.changedSinceOpenedNotice
                return false
            }
            let current = try store.revisions(of: intakeID).first { $0.number == intake.currentRevision }
            var errors: [String: String] = [:]
            var parsed: [IntakeComponent] = []
            for item in edited {
                // A draft the person did not touch is the stored component, carried through as it stands
                // rather than re-read as text. The parser is the right gate on what someone **typed**, and it
                // is narrower than the store: it refuses a zero amount, which the store, the export, the
                // importer and the encoder all accept. Validating an untouched field would therefore make
                // such an entry unsaveable at all — a time correction included, which changes no amount and
                // so should never have needed an amount validated at all.
                if let untouched = Self.unchangedStoredComponent(for: item, in: current?.components ?? []) {
                    parsed.append(untouched)
                } else if let amount = AmountParser.parseTyped(item.amountText) {
                    let stored = current?.components.first { $0.componentID == item.componentID }?.hydrationPercent
                    parsed.append(IntakeComponent(
                        componentID: item.componentID, name: item.name, amount: amount, unit: item.unit,
                        hydrationPercent: stored))
                } else {
                    errors[item.componentID] = "Enter an amount greater than zero, using digits and a point."
                }
            }
            // A drink's water share is the one the edit screen shows, on its volume components only.
            if kind == .drink, let share = waterSharePercent {
                parsed = parsed.map { component in
                    guard component.unit.dimension == .volume else { return component }
                    // A component whose stored share differs from the one shown keeps its own share.
                    guard component.hydrationPercent == loadedWaterSharePercent || component.hydrationPercent == nil else {
                        return component
                    }
                    var updated = component
                    updated.hydrationPercent = share
                    return updated
                }
            }
            fieldErrors = errors
            guard errors.isEmpty, !parsed.isEmpty else { return false }
            var product: ProductDefinition?
            if let snapshotID = current?.productSnapshotID { product = try store.product(snapshotID: snapshotID) }
            let correctedTime: Date? = storedOccurredAt == nil || storedOccurredAt == occurredAt
                ? nil
                : occurredAt
            // The time-correction reason belongs to a save that moved only the time. A save that changes the
            // amounts and the time together is an ordinary edit, and is recorded as one.
            let timeOnly = correctedTime != nil
                && (current.map { Self.componentsUnchanged(from: $0.components, to: parsed) } ?? false)
            // An amount that was typed over is no longer the amount the logged unit described, so that unit is
            // forgotten in the same commit as the edit: a failed edit forgets nothing, and the component reads as
            // the unit system says only once the amount has really changed.
            var unitRemovals: [String] = []
            if let before = current?.components {
                for component in parsed {
                    guard let old = before.first(where: { $0.componentID == component.componentID }),
                        !Self.sameAmount(old.amount, component.amount)
                    else { continue }
                    unitRemovals.append(component.componentID)
                }
            }
            try store.editRemovingUnits(
                intakeID: intakeID, components: parsed, product: product,
                changeReason: Self.recordedReason(written: reason, timeOnlyChange: timeOnly), now: now,
                occurredAt: correctedTime,
                timeZoneIdentifier: correctedTime == nil ? nil : intake.timeZoneIdentifier,
                unitRemovals: unitRemovals, expectedRevision: intake.currentRevision)
        } catch JournalError.staleRevision {
            // A write landed between the check above and this one; the store refuses it in the same commit.
            fieldErrors = [:]
            errorMessage = Self.changedSinceOpenedNotice
            return false
        } catch {
            errorMessage = "Couldn't save. Your previous amount is kept."
            return false
        }
        load(now: now)
        return true
    }

    /// What one revision is recorded as. A reason the person wrote is theirs and is kept as written;
    /// an untouched field records what actually changed.
    ///
    /// **A time correction is named only when the amounts are untouched.** A save that changes the amounts
    /// *and* the time is an ordinary edit of the entry, however it was reached, and labeling it "Time
    /// corrected" would say the time was the only thing that moved when it was not: the history would read
    /// as if the amounts had stood still through a correction that changed them. So the time-correction
    /// reason is for the case it describes — the instant moved and the components did not.
    static func recordedReason(written reason: String, timeOnlyChange: Bool) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return timeOnlyChange ? timeCorrectionReason : defaultChangeReason }
        if timeOnlyChange, trimmed == defaultChangeReason { return timeCorrectionReason }
        return trimmed
    }

    /// The stored component a draft leaves untouched, or nil when the person edited it or the revision does
    /// not hold one under that id.
    ///
    /// "Untouched" is judged against the text `load` seeded the field with, so the comparison is the one
    /// the person sees: a draft that still reads as the stored amount states the stored amount, whatever
    /// the parser would make of that text. An entry with a zero-valued component therefore keeps it, and a
    /// time correction of such an entry — which changes no amount — writes without ever validating one.
    ///
    /// A stored `unknown` **is** recognized as untouched. Its field is seeded empty, and empty is exactly
    /// what `load` put there, so an entry carrying an unknown component is read back the same way a zero or
    /// any other value the parser refuses is: the person changed nothing, and the save carries the component
    /// through as it stands.
    ///
    /// It has to be recognized, or the only edit that changes no amount cannot be made on such an entry at
    /// all: correcting the time of an entry with a component whose amount is unknown would fail on a field
    /// nobody touched. The comparison is against the text `load` seeded, so an amount field the person did
    /// clear is still empty and still refused by the parser — this recognizes *untouched*, not *absent*.
    static func unchangedStoredComponent(
        for draft: EditedComponent, in stored: [IntakeComponent]
    ) -> IntakeComponent? {
        guard let existing = stored.first(where: { $0.componentID == draft.componentID }) else { return nil }
        guard Self.sameAmountText(Self.seededAmountText(existing.amount, unit: existing.unit), draft.amountText) else { return nil }
        return existing
    }

    /// What an amount field is seeded with: its decimal text, or empty for an `unknown`, which states no
    /// amount and so has no text to seed. The unknown's field therefore reads as untouched exactly when it
    /// is still empty.
    ///
    /// A gram, kilogram, milliliter, liter, ounce or fluid ounce is seeded rounded to the digits its reading
    /// carries, in its own unit. Every other unit is seeded as stored. An amount too small for those digits
    /// keeps its full text, so a real amount never reads as none of it.
    ///
    /// The field states the stored amount at display precision, so typing the figure it shows means "the amount
    /// shown", which is the exact stored amount: the form stays clean and the exact figure is kept. Saving the
    /// shown digits would change the stored value by less than half the last digit, with nothing a reader could
    /// see change.
    static func seededAmountText(_ amount: Decimal, unit: MeasureUnit = .serving) -> String {
        guard !amount.isNaN else { return "" }
        let shown = AmountDisplay.display(amount, unit: unit, system: .metric, roundsStoredUnit: true)
        guard !shown.isBelowSmallest else { return DecimalFormatting.text(amount) }
        return DecimalFormatting.text(shown.amount)
    }

    /// Whether the components a save writes are the ones the current revision already holds.
    ///
    /// This is what separates a correction of the time from an edit that happens to include one. The
    /// comparison is by id, name, amount and unit, ignoring order: the amounts a person edits are the same
    /// facts whatever sequence the fields are listed in, and a reordered list is not a change to them.
    ///
    /// Two unknowns are the same fact, so they compare equal here. `Decimal.nan == Decimal.nan` is false, which
    /// would read an untouched unknown as a changed amount and record a save that moved only the time as an
    /// ordinary "Edited" — telling a reader the amounts changed when they did not. Comparing the seeded text
    /// instead gives the answer the draft actually states: unchanged while the field still reads as `load`
    /// left it, changed as soon as a number is typed over it.
    static func componentsUnchanged(
        from current: [IntakeComponent], to proposed: [IntakeComponent]
    ) -> Bool {
        guard current.count == proposed.count else { return false }
        return proposed.allSatisfy { candidate in
            current.contains { existing in
                existing.componentID == candidate.componentID && existing.name == candidate.name
                    && existing.unit == candidate.unit && Self.sameAmount(existing.amount, candidate.amount)
                    && existing.hydrationPercent == candidate.hydrationPercent
            }
        }
    }

    /// Amount equality that treats two unknowns as one value. Any other value compares as `Decimal` does.
    static func sameAmount(_ first: Decimal, _ second: Decimal) -> Bool {
        if first.isNaN || second.isNaN { return first.isNaN && second.isNaN }
        return first == second
    }

    /// Saves the current drafts, keeping names and units.
    @discardableResult
    public func saveDrafts(now: Date) -> Bool {
        let edited = components.map {
            EditedComponent(componentID: $0.id, name: $0.name, amountText: drafts[$0.id] ?? "", unit: $0.unit)
        }
        return save(components: edited, changeReason: changeReason, now: now)
    }

    /// Deletes the entry with one `delete` call. The view asks for confirmation first.
    @discardableResult
    public func delete(now: Date) -> Bool {
        do {
            try store.delete(intakeID: intakeID, now: now)
        } catch {
            errorMessage = "Could not delete the entry."
            return false
        }
        isDeleted = true
        errorMessage = nil
        return true
    }

    /// Changes the entry's meal as one new revision, reason "Meal changed", and reloads the screen so the
    /// meal row, the Changes list and the meal the entry is grouped under all follow. Choosing the meal the
    /// entry already states writes nothing. Refused for a meal this build does not name, and for an entry
    /// that is gone or cannot be written.
    @discardableResult
    public func changeMeal(to meal: MealLabel?, now: Date) -> Bool {
        guard canChangeMeal else { return false }
        // Choosing what the menu already shows is not a change, and reloading would drop unsaved edits.
        guard meal != selectedMeal else { return false }
        do {
            guard let editing = store as? JournalMealEditing else {
                errorMessage = "Could not change the meal."
                return false
            }
            try editing.changeMeal(intakeID: intakeID, meal: meal?.rawValue, now: now)
        } catch {
            errorMessage = "Could not change the meal."
            return false
        }
        load(now: now)
        return true
    }

    /// Creates a new intake from this one (one `create`); this entry is untouched.
    @discardableResult
    public func repeatEntry(now: Date) -> String? {
        do {
            guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }) else {
                errorMessage = "This entry is no longer available."
                return nil
            }
            return try repeater.create(repeating: intake, now: now)
        } catch IntakeRepeatError.productUnavailable {
            errorMessage = IntakeRepeatError.productUnavailableMessage
            return nil
        } catch {
            errorMessage = "Could not repeat the entry."
            return nil
        }
    }

    /// Why the last Log on other days logged nothing, for its sheet; nil when it has not run or it logged.
    @Published public private(set) var multiDayMessage: String?

    /// Logs this entry again on each chosen day (yyyy-MM-dd), at the same time of day in its own time zone;
    /// this entry is untouched. When nothing was logged the reason is in `multiDayMessage`, for the sheet to
    /// show. When a write failed and its cleanup left new entries behind, the reason is in `errorMessage`
    /// instead, for this screen: the sheet closes so the same days cannot be logged a second time.
    @discardableResult
    public func logOnDays(_ dayKeys: Set<String>, now: Date) -> MultiDayLogOutcome {
        multiDayMessage = nil
        do {
            let result = try IntakeMultiDayLogger(store: store).log(intakeID: intakeID, onDays: dayKeys, now: now)
            guard !result.createdIDs.isEmpty else {
                return nothingLogged("Nothing was logged: the days chosen are this entry's own day or still to come.")
            }
            return .logged(result)
        } catch IntakeRepeatError.productUnavailable {
            return nothingLogged(IntakeRepeatError.productUnavailableMessage)
        } catch IntakeMultiDayError.invalidDays {
            return nothingLogged("Choose 1 to \(IntakeMultiDayLogger.maximumDays) days.")
        } catch IntakeMultiDayError.unreadableTimeZone {
            return nothingLogged("This entry's time zone can't be read, so it can't be logged on other days.")
        } catch IntakeMultiDayError.partial(let remaining) {
            errorMessage = remaining.count == 1
                ? "Could not log on every day, and 1 new entry was left in the Journal. Delete it there."
                : "Could not log on every day, and \(remaining.count) new entries were left in the Journal. Delete them there."
            return .leftEntries(remaining)
        } catch IntakeMultiDayError.entryUnavailable {
            return nothingLogged("This entry is no longer available.")
        } catch {
            return nothingLogged("Could not log the entry on those days. Nothing was logged.")
        }
    }

    /// Drops the sheet's reason, for when the sheet opens again.
    public func clearMultiDayMessage() {
        multiDayMessage = nil
    }

    private func nothingLogged(_ message: String) -> MultiDayLogOutcome {
        multiDayMessage = message
        return .nothingLogged
    }

    /// The rows a product snapshot states under a name the fifteen journal nutrients do not — a
    /// compound a captured supplement panel stored under a slug of its printed name — sorted so the
    /// order is stable. A snapshot with none gives no rows.
    ///
    /// Only a row a captured panel stated with a known amount is shown. A barcode snapshot completes
    /// its own standard keys (`salt`, say) as unknown, and those are not rows a label captured, so they
    /// are left out rather than listed as "Salt unknown". The name the label printed is preferred over
    /// the one the slug spells back out, so `dha` reads `DHA`.
    static func additionalNutrients(of product: ProductDefinition?) -> [EntryNutrientRow] {
        guard let product, product.catalogOrigin == ProductOrigin.label_capture else { return [] }
        let standard = Set(NutritionFactKey.allCases.map(\.rawValue))
        return product.nutrients.filter { !standard.contains($0.key) && $0.value.isKnown }
            .map(\.key)
            .sorted()
            .map { key in
                EntryNutrientRow(
                    key: key, name: product.displayName(for: key) ?? compoundName(for: key),
                    amountText: LookedUpProduct.shownText(product.nutrients[key] ?? .unknown))
            }
    }

    /// A compound key spelled back out for the reader: `creatine-monohydrate` is `Creatine Monohydrate`.
    static func compoundName(for key: String) -> String {
        NutrientNames.displayName(for: key)
    }

    /// Where the entry's values came from, as the line under "Where this came from". A manual entry, or
    /// one with no snapshot, states no values.
    public static func sourceLine(for product: ProductDefinition?) -> String {
        guard let product, product.catalogOrigin != "manual" else { return "Typed in · no nutrition values" }
        switch product.catalogOrigin {
        case ProductOrigin.label_capture:
            return "Label scan · \(product.labelBasis)"
        case RecipeLogger.catalogOrigin:
            return "Recipe · \(product.name)"
        case IntakeContextFactCatalog.quickAddOrigin:
            return "Quick add · amounts typed in"
        default:
            return "Barcode lookup · values \(product.labelBasis)"
        }
    }

    /// The rows under "Where this came from", in order. Only what the snapshot stores is shown: a label
    /// capture records catalog version "unknown", so that version is left out, never shown as unknown.
    static func sourceDetails(for product: ProductDefinition?) -> [SourceDetailRow] {
        guard let product else { return [SourceDetailRow(label: "Source", value: "No source recorded")] }
        if product.catalogOrigin == "manual" {
            return [SourceDetailRow(label: "Input", value: "Typed in")]
        }
        let version = product.catalogVersion
        let hasVersion = !version.isEmpty && version != "unknown"
        var rows: [SourceDetailRow] = []
        switch product.catalogOrigin {
        case ProductOrigin.label_capture:
            rows.append(SourceDetailRow(label: "Input", value: "Label scan"))
            if !product.labelBasis.isEmpty {
                rows.append(SourceDetailRow(label: "Basis", value: product.labelBasis))
            }
        case RecipeLogger.catalogOrigin:
            rows.append(SourceDetailRow(label: "Input", value: "Recipe"))
            rows.append(SourceDetailRow(label: "Recipe", value: product.name))
            if !version.isEmpty {
                rows.append(SourceDetailRow(label: "Version", value: version))
            }
        case IntakeContextFactCatalog.quickAddOrigin:
            rows.append(SourceDetailRow(label: "Input", value: "Quick add"))
        default:
            rows.append(SourceDetailRow(label: "Input", value: "Barcode lookup"))
            if let barcode = product.barcode, !barcode.isEmpty {
                rows.append(SourceDetailRow(label: "Barcode", value: barcode))
            }
            if hasVersion {
                rows.append(SourceDetailRow(label: "Catalog version", value: version))
            }
            if !product.labelBasis.isEmpty {
                rows.append(SourceDetailRow(label: "Basis", value: product.labelBasis))
            }
        }
        return rows
    }

    /// "This entry adds": each standard key the snapshot states, or the tracked nutrients it states, scaled
    /// to what the entry logged. The keys follow `AddIntakeViewModel.thisAddsKeys`, so the Add form and this
    /// screen show the same rows in the same order. A value the snapshot does not state, or a basis that
    /// the logged amount cannot resolve, reads "Not on the label" and is never shown as zero, unless the
    /// snapshot states the nutrient, when it reads the cannot-scale sentence instead. A nutrient marked
    /// not applicable reads "Does not apply" either way, as it does in the Add preview.
    static func adds(of product: ProductDefinition?, logged components: [IntakeComponent]) -> [EntryNutrientRow] {
        // A typed entry, or a snapshot that states no value at all, has nothing this entry added.
        guard let product, product.catalogOrigin != "manual",
              product.nutrients.values.contains(where: { isStated($0) })
        else { return [] }
        let factor = DailyTotalsBuilder.scalingFactor(labelBasis: product.labelBasis, logged: components)
        var rows: [EntryNutrientRow] = []
        for key in AddIntakeViewModel.thisAddsKeys {
            let value = snapshotValue(for: key, in: product.nutrients)
            guard value != .unknown || LookedUpProduct.standardKeys.contains(key) else { continue }
            var amountText = "Not on the label"
            if value != .unknown, let factor {
                amountText = LookedUpProduct.shownScaledText(value.scaled(by: factor))
            } else if LookedUpProduct.statesAmount(value) {
                amountText = LookedUpProduct.cannotScaleText
            } else if value == .notApplicable {
                // Not an amount, so there is nothing to scale: it reads as it does in the Add preview.
                amountText = LookedUpProduct.shownText(value)
            }
            rows.append(EntryNutrientRow(
                key: key, name: LookedUpProduct.displayNames[key] ?? compoundName(for: key), amountText: amountText))
        }
        return rows
    }

    /// Whether a value says something the label printed: an amount, or a bound such as "<1 g". Unknown and
    /// not-applicable values say nothing and are left out.
    static func isStated(_ value: NutrientValue) -> Bool {
        switch value {
        case .known, .belowReportingThreshold: return true
        case .unknown, .notApplicable: return false
        }
    }

    /// Every nutrient the snapshot states, as the label printed it, sorted by name.
    static func allValues(of product: ProductDefinition?) -> [EntryNutrientRow] {
        guard let product else { return [] }
        var rows: [EntryNutrientRow] = []
        for (key, value) in product.nutrients where isStated(value) {
            let name = product.displayName(for: key) ?? LookedUpProduct.displayNames[key] ?? compoundName(for: key)
            rows.append(EntryNutrientRow(key: key, name: name, amountText: LookedUpProduct.shownText(value)))
        }
        return rows.sorted { ($0.name, $0.key) < ($1.name, $1.key) }
    }

    /// The value a key reads from a snapshot, trying the keys the write planner accepts for it.
    static func snapshotValue(for key: String, in nutrients: [String: NutrientValue]) -> NutrientValue {
        for accepted in HealthKitWritePlanner.acceptedKeys(for: key) {
            if let value = nutrients[accepted], value != .unknown { return value }
        }
        return .unknown
    }

    /// The changes, newest first. Revision 1 is "Logged". A later revision reads by what it changed against
    /// the one before: its components, and its time when it carries one that differs from the time the entry
    /// was last known to have. A revision with no time of its own is unchanged in time.
    static func changeRows(of revisions: [IntakeRevision]) -> [EntryChangeRow] {
        var rows: [EntryChangeRow] = []
        var previous: IntakeRevision?
        var baseline: Date?
        for revision in revisions.sorted(by: { $0.number < $1.number }) {
            var verb = "Logged"
            let mealChanged = revision.changeReason.trimmingCharacters(in: .whitespacesAndNewlines) == mealChangedReason
            if let previous {
                let amountsChanged = !componentsUnchanged(from: previous.components, to: revision.components)
                // A restored export carries no time on its revisions, so the automatic reason is the only record
                // that the time was corrected.
                let restoredTimeCorrection = revision.occurredAt == nil
                    && revision.changeReason.trimmingCharacters(in: .whitespacesAndNewlines) == timeCorrectionReason
                let timeChanged = restoredTimeCorrection
                    || (revision.occurredAt != nil && baseline != nil && revision.occurredAt != baseline)
                switch (amountsChanged, timeChanged) {
                case (true, true): verb = "Amount changed and time corrected"
                case (true, false): verb = "Amount changed"
                case (false, true): verb = "Time corrected"
                case (false, false): verb = mealChanged ? "Meal changed" : "Changed"
                }
            }
            rows.append(EntryChangeRow(
                id: revision.number, verb: verb, at: revision.createdAt,
                note: changeNote(for: revision.changeReason, verb: verb, number: revision.number)))
            baseline = revision.occurredAt ?? baseline
            previous = revision
        }
        return rows.reversed()
    }

    /// The reason a change is shown with, or nil when it says nothing the verb does not: revision 1, the
    /// creation reason, the default reason, an empty reason, and a reason that repeats the row's verb (so the
    /// automatic time-correction reason on a time-only row) are all left out.
    static func changeNote(for reason: String, verb: String, number: Int) -> String? {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // Revision 1 is stored as "created", which says nothing the "Logged" verb does not.
        if number == 1 || trimmed == creationReason || trimmed.isEmpty || trimmed == defaultChangeReason
            || trimmed == verb {
            return nil
        }
        return trimmed
    }

    /// The name of a destination as a person reads it under "Sent to".
    static func sentToLabel(_ destination: JournalDestination) -> String {
        switch destination {
        case .healthKit: return "Apple Health"
        case .relay: return "HealthRelay"
        }
    }

    /// The state of a destination as a phrase under "Sent to". Each state has its own word.
    static func sentToText(_ state: DestinationState) -> String {
        switch state {
        case .pending: return "Waiting to send"
        case .inProgress: return "Sending"
        case .succeeded: return "Sent"
        case .needsAttention: return "Needs attention"
        case .disabled: return "Not connected"
        }
    }

    static func label(_ destination: JournalDestination) -> String {
        switch destination {
        case .healthKit: return "Health app"
        case .relay: return "Relay"
        }
    }

    static func stateText(_ state: DestinationState) -> String {
        switch state {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .succeeded: return "Succeeded"
        case .needsAttention: return "Needs attention"
        case .disabled: return "Disabled"
        }
    }

    static func icon(_ state: DestinationState) -> String {
        switch state {
        case .pending: return "clock"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .needsAttention: return "exclamationmark.triangle"
        case .disabled: return "slash.circle"
        }
    }
}
