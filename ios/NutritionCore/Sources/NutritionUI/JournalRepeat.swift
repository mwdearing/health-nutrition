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

    public init(favorite: FavoriteTemplate) {
        var parsed: [IntakeComponent] = []
        for item in favorite.components {
            if let amount = Decimal(string: item.amountText, locale: AmountParser.locale), !amount.isNaN,
                let unit = try? MeasureUnit(symbol: item.unitSymbol)
            {
                parsed.append(IntakeComponent(componentID: item.componentID, name: item.name, amount: amount, unit: unit))
            }
        }
        self.init(
            displayName: favorite.displayName, category: favorite.category, components: parsed,
            productSnapshotID: favorite.productSnapshotID)
    }
}

/// Creates a NEW intake from a template: new id, now, current time zone. One `create` call.
struct IntakeRepeater {
    let store: JournalStore
    let timeZoneIdentifier: String
    let makeID: () -> String

    @discardableResult
    func create(from template: RepeatTemplate, now: Date) throws -> String {
        var product: ProductDefinition?
        if let snapshotID = template.productSnapshotID {
            product = try store.product(snapshotID: snapshotID)
        }
        let intake = Intake(
            id: makeID(), category: template.category, occurredAt: now,
            timeZoneIdentifier: timeZoneIdentifier, meal: template.meal)
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
enum AmountText {
    static func describe(_ component: IntakeComponent) -> String {
        guard !component.amount.isNaN else { return "unknown" }
        return "\(DecimalFormatting.text(component.amount)) \(component.unit.symbol)"
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
