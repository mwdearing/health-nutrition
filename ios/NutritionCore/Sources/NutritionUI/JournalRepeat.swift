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
    /// True when the entry this template was built from was logged with "Save to Library" off. Repeating the template
    /// keeps the copy out of Library too, as repeating that entry does.
    public var keepsOutOfLibrary: Bool

    public init(
        displayName: String, category: String, meal: String? = nil, components: [IntakeComponent],
        productSnapshotID: String? = nil, loggedUnits: [String: MeasureUnit] = [:], keepsOutOfLibrary: Bool = false
    ) {
        self.displayName = displayName
        self.category = category
        self.meal = meal
        self.components = components
        self.productSnapshotID = productSnapshotID
        self.loggedUnits = loggedUnits
        self.keepsOutOfLibrary = keepsOutOfLibrary
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
    func create(from template: RepeatTemplate, now: Date, keepOutOfLibrary: Bool = false, note: String? = nil) throws -> String {
        var product: ProductDefinition?
        if let snapshotID = template.productSnapshotID {
            guard let found = try store.product(snapshotID: snapshotID) else {
                throw IntakeRepeatError.productUnavailable
            }
            product = found
        }
        var intake = Intake(
            id: makeID(), category: template.category, occurredAt: now,
            timeZoneIdentifier: timeZoneProvider(), meal: template.meal)
        intake.note = note
        // The units the original was logged in are carried over, written first like the other per-entry choices.
        if let units = store as? JournalLoggedUnits {
            for component in template.components where component.unit == .mL {
                guard let loggedUnit = template.loggedUnits[component.componentID] else { continue }
                try units.recordLoggedUnit(JournalLoggedUnit(
                    intakeID: intake.id, componentID: component.componentID, unit: loggedUnit))
            }
        }
        // Written before the entry, as the Add form does, so a failure saves nothing.
        if keepOutOfLibrary || template.keepsOutOfLibrary {
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
            loggedUnits: try LoggedUnitIndex.loadOrThrow(from: store)[intake.id] ?? [:])
        let excluded = try (store as? JournalLibraryExclusions)?.intakeIDsNotSavedToLibrary() ?? []
        return try create(
            from: template, now: now, keepOutOfLibrary: excluded.contains(intake.id), note: intake.note)
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
    ///
    /// A supplement with no recorded unit (`isSupplement` true, `loggedUnit` nil: an entry or favorite from before the
    /// unit was recorded) reads as the spoon its milliliters can only have been typed in, when they are an exact spoon
    /// measure that is not also a clean fluid-ounce figure.
    static func describe(
        _ component: IntakeComponent, unitSystem: UnitSystem = .metric, loggedUnit: MeasureUnit? = nil,
        isSupplement: Bool = false
    ) -> String {
        guard !component.amount.isNaN else { return "unknown" }
        if component.unit == .mL {
            if let loggedUnit, let logged = AmountDisplay.reading(milliliters: component.amount, loggedAs: loggedUnit) {
                return logged.text
            }
            if isSupplement, loggedUnit == nil,
                let legacy = AmountDisplay.legacySpoonReading(milliliters: component.amount)
            {
                return legacy.text
            }
        }
        return AmountDisplay.display(component, system: unitSystem, roundsStoredUnit: true).text
    }

    static func name(_ component: IntakeComponent) -> String {
        let trimmed = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func summary(
        _ components: [IntakeComponent], unitSystem: UnitSystem = .metric, loggedUnits: [String: MeasureUnit] = [:],
        isSupplement: Bool = false
    ) -> String {
        components.isEmpty ? "unknown" : components.map {
            describe($0, unitSystem: unitSystem, loggedUnit: loggedUnits[$0.componentID], isSupplement: isSupplement)
        }.joined(separator: ", ")
    }

    static func title(_ components: [IntakeComponent]) -> String {
        components.isEmpty ? "unknown" : components.map { name($0) }.joined(separator: ", ")
    }
}


/// The units entries were logged in, read once per screen load: intake id, then component id.
enum LoggedUnitIndex {
    /// The same index, but a failed read throws. A write path that carries units to a new entry uses this, so a
    /// failed read stops the write instead of creating the entry without its units.
    static func loadOrThrow(from store: JournalStore) throws -> [String: [String: MeasureUnit]] {
        guard let units = store as? JournalLoggedUnits else { return [:] }
        var index: [String: [String: MeasureUnit]] = [:]
        for unit in try units.loggedUnits() { index[unit.intakeID, default: [:]][unit.componentID] = unit.unit }
        return index
    }

    /// For display: a failed read shows every amount in the unit it is stored in rather than failing the screen.
    static func load(from store: JournalStore) -> [String: [String: MeasureUnit]] {
        guard let units = (store as? JournalLoggedUnits).flatMap({ try? $0.loggedUnits() }) else { return [:] }
        var index: [String: [String: MeasureUnit]] = [:]
        for unit in units { index[unit.intakeID, default: [:]][unit.componentID] = unit.unit }
        return index
    }
}
