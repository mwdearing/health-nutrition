import Foundation
import NutritionDomain

/// One serving size as the label states it.
///
/// DSLD writes the unit as free text such as "Softgel(s)" or "tsp", which the domain unit registry does
/// not carry. A unit the registry knows is used as it is; every other unit text is read as a count of
/// `.serving` and the original text stays in `unitText`, so nothing is invented and nothing is lost.
public struct DSLDServingSize: Sendable, Hashable {
    /// The `servingSizes[].order` the label gave this serving size; quantity entries name it.
    public let order: Int
    public let minimum: Quantity
    public let maximum: Quantity
    /// The unit exactly as the label wrote it, for example "Softgel(s)".
    public let unitText: String
    /// True when the serving size is the one shown in the Supplement Facts panel.
    public let isFactsPanelServing: Bool

    public init(
        order: Int,
        minimum: Quantity,
        maximum: Quantity,
        unitText: String,
        isFactsPanelServing: Bool
    ) {
        self.order = order
        self.minimum = minimum
        self.maximum = maximum
        self.unitText = unitText
        self.isFactsPanelServing = isFactsPanelServing
    }
}

/// The facts and blends that belong to one serving size of a label.
///
/// DSLD states each ingredient row once per serving size, so a label that lists more than one serving
/// carries a different set of amounts for each. Keeping them apart stops a caller from reading the first
/// serving's amount and calling it the second serving's.
public struct DSLDServingFacts: Sendable, Hashable {
    /// The `servingSizeOrder` these amounts belong to.
    public let order: Int
    /// The serving size of the label that carries this order, when the label states one.
    public let servingSize: DSLDServingSize?
    public let facts: [CompoundFact]
    public let blends: [ProprietaryBlend]

    public init(order: Int, servingSize: DSLDServingSize?, facts: [CompoundFact], blends: [ProprietaryBlend]) {
        self.order = order
        self.servingSize = servingSize
        self.facts = facts
        self.blends = blends
    }
}

/// A recorded NIH Dietary Supplement Label Database label, parsed into domain values.
///
/// Everything here is per serving: DSLD states each ingredient row for each serving size the label
/// lists, and the adapter keeps that basis rather than normalizing it to 100 g.
public struct DSLDSupplementLabel: Sendable, Hashable {
    /// The DSLD label identifier.
    public let id: Int
    public let fullName: String
    public let brandName: String
    /// True when the label is recorded as off market.
    public let offMarket: Bool
    public let servingSizes: [DSLDServingSize]
    /// One fact per ingredient row that is not a proprietary blend, for the first serving size.
    public let facts: [CompoundFact]
    /// One entry per proprietary blend row, for the first serving size. A blend total is not repeated in `facts`.
    public let blends: [ProprietaryBlend]
    /// The facts and blends of every serving size the label lists, in label order. This is the whole
    /// label: `facts` and `blends` are only its first entry, kept for the common single-serving case.
    public let servings: [DSLDServingFacts]

    public init(
        id: Int,
        fullName: String,
        brandName: String,
        offMarket: Bool,
        servingSizes: [DSLDServingSize],
        facts: [CompoundFact],
        blends: [ProprietaryBlend],
        servings: [DSLDServingFacts] = []
    ) {
        self.id = id
        self.fullName = fullName
        self.brandName = brandName
        self.offMarket = offMarket
        self.servingSizes = servingSizes
        self.facts = facts
        self.blends = blends
        self.servings = servings
    }

    /// The facts and blends of one serving size, by its `servingSizeOrder`. Unknown when the label does
    /// not state that serving size; nothing is ever returned from a different serving size instead.
    public func serving(_ order: Int) -> DSLDServingFacts? {
        servings.first { $0.order == order }
    }

    /// The fact with this label name, if the label has one.
    public func fact(named name: String) -> CompoundFact? {
        facts.first { $0.labelName == name }
    }
}