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

    public init(
        displayName: String, category: String, meal: String? = nil, components: [IntakeComponent],
        productSnapshotID: String? = nil
    ) {
        self.displayName = displayName
        self.category = category
        self.meal = meal
        self.components = components
        self.productSnapshotID = productSnapshotID
    }

    /// Returns nil when any component has a malformed amount or unit: the whole template is rejected.
    public init?(favorite: FavoriteTemplate) {
        var parsed: [IntakeComponent] = []
        for item in favorite.components {
            guard let amount = AmountParser.parse(item.amountText),
                let unit = try? MeasureUnit(symbol: item.unitSymbol)
            else { return nil }
            parsed.append(IntakeComponent(componentID: item.componentID, name: item.name, amount: amount, unit: unit))
        }
        self.init(
            displayName: favorite.displayName, category: favorite.category, meal: favorite.meal, components: parsed,
            productSnapshotID: favorite.productSnapshotID)
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
    func create(from template: RepeatTemplate, now: Date) throws -> String {
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
        try store.create(intake, components: template.components, product: product, now: now)
        return intake.id
    }

    /// Reads the intake's current revision and repeats it.
    @discardableResult
    func create(repeating intake: Intake, now: Date) throws -> String {
        let revisions = try store.revisions(of: intake.id)
        guard let current = revisions.first(where: { $0.number == intake.currentRevision }) else {
            throw JournalError.corruptRecord(intake.id)
        }
        let template = RepeatTemplate(
            displayName: "", category: intake.category, meal: intake.meal, components: current.components,
            productSnapshotID: current.productSnapshotID)
        return try create(from: template, now: now)
    }
}

/// Text for amounts: a missing or invalid amount is "unknown", never 0.
///
/// `unitSystem` only decides which unit the amount is SHOWN in. The value is never changed, so the
/// stored number stays the number that was entered.
enum AmountText {
    static func describe(_ component: IntakeComponent, unitSystem: UnitSystem = .metric) -> String {
        guard !component.amount.isNaN else { return "unknown" }
        return AmountDisplay.display(component, system: unitSystem).text
    }

    static func name(_ component: IntakeComponent) -> String {
        let trimmed = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func summary(_ components: [IntakeComponent]) -> String {
        components.isEmpty ? "unknown" : components.map { describe($0) }.joined(separator: ", ")
    }

    static func title(_ components: [IntakeComponent]) -> String {
        components.isEmpty ? "unknown" : components.map { name($0) }.joined(separator: ", ")
    }
}
