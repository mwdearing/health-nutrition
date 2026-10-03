import Foundation
import NutritionDomain
import NutritionJournal

public struct EntryComponentRow: Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Exact decimal text, or "unknown".
    public let amountText: String
    public let unit: MeasureUnit
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
    @Published public private(set) var components: [EntryComponentRow] = []
    @Published public private(set) var revisions: [EntryRevisionRow] = []
    @Published public private(set) var destinations: [EntryDestinationRow] = []
    @Published public private(set) var currentRevision: Int = 0
    @Published public private(set) var fieldErrors: [String: String] = [:]
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isDeleted = false
    /// Edit drafts by component id, bound to the text fields.
    @Published public var drafts: [String: String] = [:]
    @Published public var changeReason: String = "Edited"

    public let intakeID: String
    private let store: JournalStore
    private let repeater: IntakeRepeater

    public init(
        store: JournalStore,
        intakeID: String,
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.intakeID = intakeID
        self.repeater = IntakeRepeater(
            store: store, timeZoneProvider: IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider),
            makeID: makeID)
    }

    public func load(now: Date) {
        do {
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
            drafts = Dictionary(uniqueKeysWithValues: current.components.map {
                ($0.componentID, $0.amount.isNaN ? "" : DecimalFormatting.text($0.amount))
            })
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

    /// Writes one new revision with exactly one `edit` call. Invalid amounts write nothing.
    @discardableResult
    public func save(components edited: [EditedComponent], changeReason reason: String, now: Date) -> Bool {
        var errors: [String: String] = [:]
        var parsed: [IntakeComponent] = []
        for item in edited {
            if let amount = AmountParser.parse(item.amountText) {
                parsed.append(IntakeComponent(componentID: item.componentID, name: item.name, amount: amount, unit: item.unit))
            } else {
                errors[item.componentID] = "Enter an amount greater than zero, using digits and a point."
            }
        }
        fieldErrors = errors
        guard errors.isEmpty, !parsed.isEmpty else { return false }
        do {
            guard let intake = try store.activeIntakes().first(where: { $0.id == intakeID }) else {
                errorMessage = "This entry is no longer available."
                return false
            }
            let snapshotID = try store.revisions(of: intakeID).first { $0.number == intake.currentRevision }?.productSnapshotID
            var product: ProductDefinition?
            if let snapshotID { product = try store.product(snapshotID: snapshotID) }
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.edit(
                intakeID: intakeID, components: parsed, product: product,
                changeReason: trimmedReason.isEmpty ? "Edited" : trimmedReason, now: now)
        } catch {
            errorMessage = "Could not save the change. The previous version is kept."
            return false
        }
        load(now: now)
        return true
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
