import Foundation

/// What a mass amount measures: the whole compound (for example a salt), the active nutrient inside it,
/// or nothing the label states (unknown). Unknown is never treated as either of the other two.
public enum QuantityBasis: String, Sendable, Hashable, Codable, CaseIterable {
    case compoundMass
    case activeNutrientMass
    case unknown
}

/// How a fact takes part in totals.
public enum AggregationRole: String, Sendable, Hashable, Codable, CaseIterable {
    case contextOnly
    case compoundMeasurement
    case blendTotalOnly
}

/// The kind of a fact: a plain nutrient, a compound or a proprietary blend total.
public enum FactKind: String, Sendable, Hashable, Codable, CaseIterable {
    case nutrient
    case compound
    case blend
}

public enum CompoundError: Error, Sendable, Equatable {
    case emptyField(String)
    case invalidRole(kind: FactKind, role: AggregationRole)
    case invalidBasis(kind: FactKind, basis: QuantityBasis)
    case missingEquivalenceFactor
    case equivalenceFactorOutOfRange(Decimal)
    case missingSourceReference
    case basisNotCompoundMass(QuantityBasis)
    case basisUnknown
    case notMassAmount(MeasureUnit)
    case totalNeedsDeclaredBasis
}

/// A caller-supplied factor that turns compound mass into active nutrient mass (mass to mass).
/// The module holds no factor table: every factor comes with the reference it was taken from.
public struct EquivalenceFactor: Sendable, Hashable {
    public let value: Decimal
    public let sourceReference: String

    public init(value: Decimal, sourceReference: String) throws {
        guard value > 0, value < 1 else {
            throw CompoundError.equivalenceFactorOutOfRange(value)
        }
        let trimmed = sourceReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CompoundError.missingSourceReference
        }
        self.value = value
        self.sourceReference = trimmed
    }
}

/// The result of an explicit conversion: the active nutrient amount, with the factor and the original compound amount kept.
public struct ActiveNutrientAmount: Sendable, Hashable {
    public let compoundSubstanceIdentifier: String
    public let compoundAmount: NutrientValue
    public let amount: NutrientValue
    public let equivalence: EquivalenceFactor

    public init(
        compoundSubstanceIdentifier: String,
        compoundAmount: NutrientValue,
        amount: NutrientValue,
        equivalence: EquivalenceFactor
    ) {
        self.compoundSubstanceIdentifier = compoundSubstanceIdentifier
        self.compoundAmount = compoundAmount
        self.amount = amount
        self.equivalence = equivalence
    }
}

/// One stated amount on a label, with what the amount measures and how it may be aggregated.
/// Kind and role must agree: nutrient with contextOnly, compound with compoundMeasurement, blend with blendTotalOnly.
public struct CompoundFact: Sendable, Hashable {
    public let kind: FactKind
    public let substanceIdentifier: String
    public let labelName: String
    public let chemicalForm: String?
    public let amount: NutrientValue
    public let basis: QuantityBasis
    public let role: AggregationRole
    public let blendIdentifier: String?
    public let provenance: String?

    public init(
        kind: FactKind,
        substanceIdentifier: String,
        labelName: String,
        chemicalForm: String? = nil,
        amount: NutrientValue,
        basis: QuantityBasis,
        role: AggregationRole,
        blendIdentifier: String? = nil,
        provenance: String? = nil
    ) throws {
        guard !substanceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompoundError.emptyField("substanceIdentifier")
        }
        guard !labelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompoundError.emptyField("labelName")
        }
        let expectedRole: AggregationRole
        switch kind {
        case .nutrient:
            expectedRole = .contextOnly
        case .compound:
            expectedRole = .compoundMeasurement
        case .blend:
            expectedRole = .blendTotalOnly
        }
        guard role == expectedRole else {
            throw CompoundError.invalidRole(kind: kind, role: role)
        }
        if kind == .nutrient && basis == .compoundMass {
            throw CompoundError.invalidBasis(kind: kind, basis: basis)
        }
        self.kind = kind
        self.substanceIdentifier = substanceIdentifier
        self.labelName = labelName
        self.chemicalForm = chemicalForm
        self.amount = amount
        self.basis = basis
        self.role = role
        self.blendIdentifier = blendIdentifier
        self.provenance = provenance
    }

    /// A plain nutrient fact (role contextOnly). The basis may be activeNutrientMass or unknown.
    public static func nutrient(
        substanceIdentifier: String,
        labelName: String,
        chemicalForm: String? = nil,
        amount: NutrientValue,
        basis: QuantityBasis = .activeNutrientMass,
        blendIdentifier: String? = nil,
        provenance: String? = nil
    ) throws -> CompoundFact {
        try CompoundFact(
            kind: .nutrient,
            substanceIdentifier: substanceIdentifier,
            labelName: labelName,
            chemicalForm: chemicalForm,
            amount: amount,
            basis: basis,
            role: .contextOnly,
            blendIdentifier: blendIdentifier,
            provenance: provenance
        )
    }

    /// A compound fact (role compoundMeasurement) with a declared basis.
    public static func compound(
        substanceIdentifier: String,
        labelName: String,
        chemicalForm: String? = nil,
        amount: NutrientValue,
        basis: QuantityBasis,
        blendIdentifier: String? = nil,
        provenance: String? = nil
    ) throws -> CompoundFact {
        try CompoundFact(
            kind: .compound,
            substanceIdentifier: substanceIdentifier,
            labelName: labelName,
            chemicalForm: chemicalForm,
            amount: amount,
            basis: basis,
            role: .compoundMeasurement,
            blendIdentifier: blendIdentifier,
            provenance: provenance
        )
    }

    /// The amount, but only when the fact declares exactly this basis; otherwise nil. No inference between bases.
    public func amountReported(as requested: QuantityBasis) -> NutrientValue? {
        guard basis == requested, requested != .unknown else {
            return nil
        }
        return amount
    }

    /// Converts a compound mass to the active nutrient mass with an explicit factor. Without a factor it throws.
    /// Only a fact declared as compoundMass converts; international units and other non-mass amounts are refused;
    /// value states other than known pass through unchanged.
    public func activeNutrientAmount(equivalence: EquivalenceFactor?) throws -> ActiveNutrientAmount {
        switch basis {
        case .compoundMass:
            break
        case .activeNutrientMass:
            throw CompoundError.basisNotCompoundMass(basis)
        case .unknown:
            throw CompoundError.basisUnknown
        }
        guard let equivalence else {
            throw CompoundError.missingEquivalenceFactor
        }
        let converted: NutrientValue
        switch amount {
        case .known(let value, let unit):
            guard unit.dimension == .mass else {
                throw CompoundError.notMassAmount(unit)
            }
            converted = .known(value * equivalence.value, unit)
        case .belowReportingThreshold(let unit):
            if let unit, unit.dimension != .mass {
                throw CompoundError.notMassAmount(unit)
            }
            converted = amount
        case .unknown, .notApplicable:
            converted = amount
        }
        return ActiveNutrientAmount(
            compoundSubstanceIdentifier: substanceIdentifier,
            compoundAmount: amount,
            amount: converted,
            equivalence: equivalence
        )
    }
}
