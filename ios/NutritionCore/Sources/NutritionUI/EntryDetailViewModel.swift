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
    /// Exact decimal text with its unit, or a word for a value that states no amount.
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
    /// State as words, so colour is never the only signal.
    public let stateText: String
    public let iconName: String
    /// The destination's name as a person reads it, e.g. "Apple Health".
    public let sentToLabel: String
    /// The state as a phrase under "Sent to", e.g. "Waiting to send".
    public let sentToText: String
    /// The destination's state as a value, so a reader compares states rather than their words.
    public let state: DestinationState
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

@MainActor
public final class EntryDetailViewModel: ObservableObject {
    /// The reason a revision carries when the person did not write one.
    public static let defaultChangeReason = "Edited"
    /// What a correction of the entry's time alone is recorded as, because a history that reads
    /// "Edited" for a change of time tells a reader nothing about what happened.
    public static let timeCorrectionReason = "Time corrected"
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
    /// True for an entry with no values of its own: typed by hand, with no snapshot or a manual one.
    @Published public private(set) var isTypedEntry = true
    /// The product's name and brand, and what kind of thing it is, for the header. Nil when there is no snapshot.
    @Published public private(set) var productName: String?
    @Published public private(set) var brand: String?
    @Published public private(set) var kind: ProductKind = .food
    /// The entry's changes, newest first.
    @Published public private(set) var changes: [EntryChangeRow] = []
    @Published public private(set) var revisions: [EntryRevisionRow] = []
    @Published public private(set) var destinations: [EntryDestinationRow] = []
    @Published public private(set) var currentRevision: Int = 0
    @Published public private(set) var fieldErrors: [String: String] = [:]
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isDeleted = false
    /// Edit drafts by component id, bound to the text fields.
    @Published public var drafts: [String: String] = [:]
    @Published public var changeReason: String = EntryDetailViewModel.defaultChangeReason
    /// The entry's time as an editable draft, which the "When" row binds to. `load` seeds it from
    /// the stored value, and a save writes a correction only once it differs from it.
    @Published public var occurredAt: Date
    /// The meal the entry states, as words, or nil when it states none.
    @Published public private(set) var mealText: String?
    /// The time exactly as the journal holds it, and nil until `load` has read the entry. A draft
    /// may only correct that, so a save made before the first load cannot move an entry whose
    /// stored time this model has not seen.
    private var storedOccurredAt: Date?
    /// The amount drafts as `load` seeded them, so `isDirty` compares what the person has typed with
    /// what the entry states.
    private var loadedDrafts: [String: String] = [:]
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
    /// Read on each load, so a preference changed on another screen is honoured here too.
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
            isTypedEntry = snapshot == nil || snapshot?.catalogOrigin == "manual"
            productName = snapshot?.name
            brand = snapshot?.brand
            kind = snapshot?.kind ?? .food
            allValues = Self.allValues(of: snapshot)
            adds = Self.adds(of: snapshot, logged: current.components)
            drafts = Dictionary(uniqueKeysWithValues: current.components.map {
                ($0.componentID, $0.amount.isNaN ? "" : DecimalFormatting.text($0.amount))
            })
            loadedDrafts = drafts
            occurredAt = intake.occurredAt
            storedOccurredAt = intake.occurredAt
            timeZoneIdentifier = intake.timeZoneIdentifier
            mealText = MealLabel.displayName(for: intake.meal)
            revisions = all.reversed().map {
                EntryRevisionRow(number: $0.number, createdAt: $0.createdAt, changeReason: $0.changeReason)
            }
            changes = Self.changeRows(of: all)
            let projections = try store.projections(of: intakeID).filter { $0.isCurrent }
            destinations = projections.sorted { $0.destination.rawValue < $1.destination.rawValue }.map {
                EntryDestinationRow(
                    destination: $0.destination, label: Self.label($0.destination),
                    stateText: Self.stateText($0.state), iconName: Self.icon($0.state),
                    sentToLabel: Self.sentToLabel($0.destination), sentToText: Self.sentToText($0.state),
                    state: $0.state)
            }
            fieldErrors = [:]
            errorMessage = nil
            changeReason = EntryDetailViewModel.defaultChangeReason
        } catch {
            errorMessage = "Could not read this entry."
        }
    }

    /// Whether the screen holds a change the person has not saved: an amount draft that differs from
    /// the one the entry states, or a time that differs from the stored one. Save is offered only then.
    public var isDirty: Bool {
        for id in Set(drafts.keys).union(loadedDrafts.keys)
        where !Self.sameAmountText(loadedDrafts[id] ?? "", drafts[id] ?? "") {
            return true
        }
        guard let storedOccurredAt else { return false }
        return occurredAt != storedOccurredAt
    }

    /// Whether two amount texts state the same amount. Both are trimmed; when both parse, the decimals
    /// decide, so "40.0" and " 40 " match a stored 40. Otherwise the trimmed text decides.
    static func sameAmountText(_ loaded: String, _ draft: String) -> Bool {
        let first = loaded.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = AmountParser.parse(first), let b = AmountParser.parse(second) { return a == b }
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
              let draft = drafts[componentID], let amount = AmountParser.parse(draft)
        else { return nil }
        return AmountDisplay.display(amount, unit: row.unit, system: preferences.unitSystem).text
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
                } else if let amount = AmountParser.parse(item.amountText) {
                    parsed.append(IntakeComponent(componentID: item.componentID, name: item.name, amount: amount, unit: item.unit))
                } else {
                    errors[item.componentID] = "Enter an amount greater than zero, using digits and a point."
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
            try store.edit(
                intakeID: intakeID, components: parsed, product: product,
                changeReason: Self.recordedReason(written: reason, timeOnlyChange: timeOnly), now: now,
                occurredAt: correctedTime,
                timeZoneIdentifier: correctedTime == nil ? nil : intake.timeZoneIdentifier)
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
    /// *and* the time is an ordinary edit of the entry, however it was reached, and labelling it "Time
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
    /// A stored `unknown` **is** recognised as untouched. Its field is seeded empty, and empty is exactly
    /// what `load` put there, so an entry carrying an unknown component is read back the same way a zero or
    /// any other value the parser refuses is: the person changed nothing, and the save carries the component
    /// through as it stands.
    ///
    /// It has to be recognised, or the only edit that changes no amount cannot be made on such an entry at
    /// all: correcting the time of an entry with a component whose amount is unknown would fail on a field
    /// nobody touched. The comparison is against the text `load` seeded, so an amount field the person did
    /// clear is still empty and still refused by the parser — this recognises *untouched*, not *absent*.
    static func unchangedStoredComponent(
        for draft: EditedComponent, in stored: [IntakeComponent]
    ) -> IntakeComponent? {
        guard let existing = stored.first(where: { $0.componentID == draft.componentID }) else { return nil }
        guard Self.sameAmountText(Self.seededAmountText(existing.amount), draft.amountText) else { return nil }
        return existing
    }

    /// What an amount field is seeded with: its decimal text, or empty for an `unknown`, which states no
    /// amount and so has no text to seed. The unknown's field therefore reads as untouched exactly when it
    /// is still empty.
    static func seededAmountText(_ amount: Decimal) -> String {
        amount.isNaN ? "" : DecimalFormatting.text(amount)
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
        key.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
        default:
            return "Barcode lookup · values \(product.labelBasis)"
        }
    }

    /// "This entry adds": each standard key the snapshot states, or the tracked nutrients it states, scaled
    /// to what the entry logged. The keys follow `AddIntakeViewModel.thisAddsKeys`, so the Add form and this
    /// screen show the same rows in the same order. A value the snapshot does not state, or a basis that
    /// the logged amount cannot resolve, reads "Not on the label" and is never shown as zero.
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
                amountText = LookedUpProduct.shownText(value.scaled(by: factor))
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
                case (false, false): verb = "Changed"
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
