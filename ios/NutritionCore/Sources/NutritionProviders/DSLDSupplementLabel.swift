import Foundation
import NutritionDomain

/// One serving size as the label states it.
///
/// DSLD writes the unit as free text such as "Softgel(s)" or "tsp", which the domain unit registry does
/// not carry. A unit the registry knows is used as it is; every other unit text is read as a count of
/// `.serving` and the original text stays in `unitText`, so nothing is invented and nothing is lost.
public struct DSLDServingSize: Sendable, Hashable {
    public let minimum: Quantity
    public let maximum: Quantity
    /// The unit exactly as the label wrote it, for example "Softgel(s)".
    public let unitText: String
    /// True when the serving size is the one shown in the Supplement Facts panel.
    public let isFactsPanelServing: Bool

    public init(minimum: Quantity, maximum: Quantity, unitText: String, isFactsPanelServing: Bool) {
        self.minimum = minimum
        self.maximum = maximum
        self.unitText = unitText
        self.isFactsPanelServing = isFactsPanelServing
    }
}

/// A recorded NIH Dietary Supplement Label Database label, parsed into domain values.
///
/// Everything here is per serving: DSLD states each ingredient row for one serving size, and the
/// adapter keeps that basis rather than normalising it to 100 g.
public struct DSLDSupplementLabel: Sendable, Hashable {
    /// The DSLD label identifier.
    public let id: Int
    public let fullName: String
    public let brandName: String
    /// True when the label is recorded as off market.
    public let offMarket: Bool
    public let servingSizes: [DSLDServingSize]
    /// One fact per ingredient row that is not a proprietary blend.
    public let facts: [CompoundFact]
    /// One entry per proprietary blend row. A blend total is not repeated in `facts`.
    public let blends: [ProprietaryBlend]

    public init(
        id: Int,
        fullName: String,
        brandName: String,
        offMarket: Bool,
        servingSizes: [DSLDServingSize],
        facts: [CompoundFact],
        blends: [ProprietaryBlend]
    ) {
        self.id = id
        self.fullName = fullName
        self.brandName = brandName
        self.offMarket = offMarket
        self.servingSizes = servingSizes
        self.facts = facts
        self.blends = blends
    }

    /// The fact with this label name, if the label has one.
    public func fact(named name: String) -> CompoundFact? {
        facts.first { $0.labelName == name }
    }
}