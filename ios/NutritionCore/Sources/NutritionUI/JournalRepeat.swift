import Foundation
import NutritionDomain
import NutritionJournal

/// What a repeat copies: a category, components and an optional product snapshot id.
public struct RepeatTemplate: Equatable {
    public var displayName: String
    public var category: String
    public var meal: String?
    public var components: [IntakeComponent]
    public var productSnapshotID: String?
    /// The unit each component was logged in, by component id, when the entry it came from was logged in a spoon,
    /// a cup or fluid ounces. Repeating the template logs the same units.
    public var loggedUnits: [String: MeasureUnit]

    public init(
        displayName: String, category: String, meal: String? = nil, components: [IntakeComponent],
        productSnapshotID: String? = nil, loggedUnits: [String: MeasureUnit] = [:]
    ) {
        self.displayName = displayName
        self.category = category
        self.meal = meal
        self.components = components
        self.productSnapshotID = productSnapshotID
        self.loggedUnits = loggedUnits
    }

    /// Returns nil when any component has a malformed amount or unit: the whole template is rejected.
    public init?(favorite: FavoriteTemplate, loggedUnitIndex: [String: [String: MeasureUnit]] = [:]) {
        var parsed: [IntakeComponent] = []
        for item in favorite.components {
            guard let amount = AmountParser.parse(item.amountText),
                let unit = try? MeasureUnit(symbol: item.unitSymbol)
            else { return nil }
            parsed.append(IntakeComponent(componentID: item.componentID, name: item.name, amount: amount, unit: unit))
        }
        self.init(
            displayName: favorite.displayName, category: favorite.category, meal: favorite.meal, components: parsed,
            productSnapshotID: favorite.productSnapshotID, loggedUnits: loggedUnitIndex[favorite.id] ?? [:])
    }
}

/// Why a repeat was refused before anything was written.
enum IntakeRepeatError: Error, Equatable {
    case productUnavailable

    static let productUnavailableMessage = "The product for this item is no longer available."
}

/// Creates a NEW intake from a template: new id, now, current time zone. One `create` call.
struct IntakeRepeater {
    let store: JournalStore
    /// Resolved at create time, so a zone change after init is honored.
    let timeZoneProvider: () -> String
    let makeID: () -> String

    /// A fixed override wins; otherwise the provider is asked on every create.
    static func resolver(override: String?, provider: @escaping () -> String) -> () -> String {
        if let override { return { override } }
        return provider
    }

    @discardableResult
    func create(from template: RepeatTemplate, now: Date, keepOutOfLibrary: Bool = false) throws -> String {
        var product: ProductDefinition?
        if let snapshotID = template.productSnapshotID {
            guard let found = try store.product(snapshotID: snapshotID) else {
                throw IntakeRepeatError.productUnavailable
            }
            product = found
        }
        let intake = Intake(
            id: makeID(), category: template.category, occurredAt: now,
            timeZoneIdentifier: timeZoneProvider(), meal: template.meal)
        // The units the original was logged in are carried over, written first like the other per-entry choices.
        if let units = store as? JournalLoggedUnits {
            for component in template.components where component.unit == .mL {
                guard let loggedUnit = template.loggedUnits[component.componentID] else { continue }
                try units.recordLoggedUnit(JournalLoggedUnit(
                    intakeID: intake.id, componentID: component.componentID, unit: loggedUnit))
            }
        }
        // Written before the entry, as the Add form does, so a failure saves nothing.
        if keepOutOfLibrary {
            guard let exclusions = store as? JournalLibraryExclusions else {
                throw IntakeRepeatError.productUnavailable
            }
            try exclusions.keepOutOfLibrary(intakeID: intake.id)
        }
        try store.create(intake, components: template.components, product: product, now: now)
        return intake.id
    }

    /// Reads the intake's current revision and repeats it. A copy of an entry kept out of Library
    /// stays out of Library too.
    @discardableResult
    func create(repeating intake: Intake, now: Date) throws -> String {
        let revisions = try store.revisions(of: intake.id)
        guard let current = revisions.first(where: { $0.number == intake.currentRevision }) else {
            throw JournalError.corruptRecord(intake.id)
        }
        let template = RepeatTemplate(
            displayName: "", category: intake.category, meal: intake.meal, components: current.components,
            productSnapshotID: current.productSnapshotID,
            loggedUnits: LoggedUnitIndex.load(from: store)[intake.id] ?? [:])
        let excluded = try (store as? JournalLibraryExclusions)?.intakeIDsNotSavedToLibrary() ?? []
        return try create(from: template, now: now, keepOutOfLibrary: excluded.contains(intake.id))
    }
}

/// Text for amounts: a missing or invalid amount is "unknown", never 0.
///
/// `unitSystem` only decides which unit the amount is SHOWN in. The value is never changed, so the
/// stored number stays the number that was entered.
enum AmountText {
    /// A supplement logged by the spoon is stored in milliliters, so it reads back in the unit it was logged in
    /// (`loggedUnit`, passed only for supplements) rather than in the unit system's fluid ounces. Drinks and
    /// everything else pass nil and read as the unit system says.
    static func describe(
        _ component: IntakeComponent, unitSystem: UnitSystem = .metric, loggedUnit: MeasureUnit? = nil
    ) -> String {
        guard !component.amount.isNaN else { return "unknown" }
        if let loggedUnit, component.unit == .mL,
            let logged = AmountDisplay.reading(milliliters: component.amount, loggedAs: loggedUnit)
        {
            return logged.text
        }
        return AmountDisplay.display(component, system: unitSystem, roundsStoredUnit: true).text
    }

    static func name(_ component: IntakeComponent) -> String {
        let trimmed = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func summary(
        _ components: [IntakeComponent], unitSystem: UnitSystem = .metric, loggedUnits: [String: MeasureUnit] = [:]
    ) -> String {
        components.isEmpty ? "unknown" : components.map {
            describe($0, unitSystem: unitSystem, loggedUnit: loggedUnits[$0.componentID])
        }.joined(separator: ", ")
    }

    static func title(_ components: [IntakeComponent]) -> String {
        components.isEmpty ? "unknown" : components.map { name($0) }.joined(separator: ", ")
    }
}


/// The units entries were logged in, read once per screen load: intake id, then component id.
enum LoggedUnitIndex {
    static func load(from store: JournalStore) -> [String: [String: MeasureUnit]] {
        guard let units = (store as? JournalLoggedUnits).flatMap({ try? $0.loggedUnits() }) else { return [:] }
        var index: [String: [String: MeasureUnit]] = [:]
        for unit in units { index[unit.intakeID, default: [:]][unit.componentID] = unit.unit }
        return index
    }
}
