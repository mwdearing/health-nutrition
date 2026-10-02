import Foundation

/// One named ingredient of a proprietary blend. An amount the label does not disclose stays `unknown`.
public struct BlendMember: Sendable, Hashable {
    public let labelName: String
    public let substanceIdentifier: String?
    public let amount: NutrientValue

    public init(labelName: String, substanceIdentifier: String? = nil, amount: NutrientValue = .unknown) {
        self.labelName = labelName
        self.substanceIdentifier = substanceIdentifier
        self.amount = amount
    }
}

/// A proprietary blend: one stated total and its members. The total is never divided among the members,
/// and the members are never added to the total.
public struct ProprietaryBlend: Sendable, Hashable {
    public let identifier: String
    public let labelName: String
    public let basis: QuantityBasis
    public let members: [BlendMember]
    /// The blend total as a fact with kind blend and role blendTotalOnly.
    public let totalFact: CompoundFact

    public var total: NutrientValue {
        totalFact.amount
    }

    public var undisclosedMembers: [BlendMember] {
        members.filter { member in
            if case .unknown = member.amount {
                return true
            }
            return false
        }
    }

    public init(
        identifier: String,
        labelName: String,
        total: NutrientValue,
        basis: QuantityBasis = .compoundMass,
        members: [BlendMember] = [],
        provenance: String? = nil
    ) throws {
        self.totalFact = try CompoundFact(
            kind: .blend,
            substanceIdentifier: identifier,
            labelName: labelName,
            amount: total,
            basis: basis,
            role: .blendTotalOnly,
            provenance: provenance
        )
        self.identifier = identifier
        self.labelName = labelName
        self.basis = basis
        self.members = members
    }
}

/// Totals one substance for one basis over facts and blends.
public enum SupplementTotals: Sendable {
    /// Sums the facts of `substance` that declare `basis`. Facts of another declared basis are left out;
    /// facts with basis unknown count as unknown (partial coverage), never as a guess.
    /// A blend total counts exactly once (also when it appears in both `facts` and `blends`);
    /// blend members are never added, and a member with an undisclosed amount makes its substance total partial.
    public static func total(
        substance: String,
        basis: QuantityBasis,
        facts: [CompoundFact],
        blends: [ProprietaryBlend] = [],
        in unit: MeasureUnit? = nil
    ) throws -> NutrientTotal {
        guard basis != .unknown else {
            throw CompoundError.totalNeedsDeclaredBasis
        }
        var values: [NutrientValue] = []
        var countedBlendTotals = Set<String>()
        var seenBlends = Set<String>()

        for fact in facts where fact.substanceIdentifier == substance {
            if fact.role == .blendTotalOnly {
                guard countedBlendTotals.insert(fact.substanceIdentifier).inserted else {
                    continue
                }
            }
            if let value = contribution(factBasis: fact.basis, requested: basis, amount: fact.amount) {
                values.append(value)
            }
        }

        for blend in blends {
            guard seenBlends.insert(blend.identifier).inserted else {
                continue
            }
            if blend.identifier == substance, countedBlendTotals.insert(blend.identifier).inserted {
                if let value = contribution(factBasis: blend.basis, requested: basis, amount: blend.total) {
                    values.append(value)
                }
            }
            for member in blend.members where member.substanceIdentifier == substance {
                if case .unknown = member.amount {
                    values.append(.unknown)
                }
            }
        }

        return try NutrientTotal.sum(values, in: unit)
    }

    private static func contribution(
        factBasis: QuantityBasis,
        requested: QuantityBasis,
        amount: NutrientValue
    ) -> NutrientValue? {
        if factBasis == requested {
            return amount
        }
        if factBasis == .unknown {
            return NutrientValue.unknown
        }
        return nil
    }
}
