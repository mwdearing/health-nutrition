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

public struct EntryDestinationRow: Equatable, Identifiable {
    public var id: String { destination.rawValue }
    public let destination: JournalDestination
    public let label: String
    /// State as words, so colour is never the only signal.
    public let stateText: String
    public let iconName: String
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

    @Published public private(set) var components: [EntryComponentRow] = []
    /// The compounds the product snapshot states under names the fifteen journal nutrients do not, so a
    /// scanned supplement's own rows are visible where the entry's amounts are shown.
    @Published public private(set) var additionalNutrients: [EntryNutrientRow] = []
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
            drafts = Dictionary(uniqueKeysWithValues: current.components.map {
                ($0.componentID, $0.amount.isNaN ? "" : DecimalFormatting.text($0.amount))
            })
            occurredAt = intake.occurredAt
            storedOccurredAt = intake.occurredAt
            timeZoneIdentifier = intake.timeZoneIdentifier
            mealText = MealLabel.displayName(for: intake.meal)
            revisions = all.reversed().map {
                EntryRevisionRow(number: $0.number, createdAt: $0.createdAt, changeReason: $0.changeReason)
            }
            let projections = try store.projections(of: intakeID).filter { $0.isCurrent }
            destinations = projections.sorted { $0.destination.rawValue < $1.destination.rawValue }.map {
                EntryDestinationRow(
                    destination: $0.destination, label: Self.label($0.destination),
                    stateText: Self.stateText($0.state), iconName: Self.icon($0.state))
            }
            fieldErrors = [:]
            errorMessage = nil
        } catch {
            errorMessage = "Could not read this entry."
        }
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
            errorMessage = "Could not save the change. The previous version is kept."
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
        let text = draft.amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == Self.seededAmountText(existing.amount) else { return nil }
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
    static func additionalNutrients(of product: ProductDefinition?) -> [EntryNutrientRow] {
        guard let product else { return [] }
        let standard = Set(NutritionFactKey.allCases.map(\.rawValue))
        return product.nutrients.keys.filter { !standard.contains($0) }
            .sorted()
            .map { key in
                EntryNutrientRow(
                    key: key, name: compoundName(for: key),
                    amountText: LookedUpProduct.describe(product.nutrients[key] ?? .unknown))
            }
    }

    /// A compound key spelled back out for the reader: `creatine-monohydrate` is `Creatine Monohydrate`.
    static func compoundName(for key: String) -> String {
        key.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
