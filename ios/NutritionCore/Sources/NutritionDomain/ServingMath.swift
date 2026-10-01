import Foundation

/// The reference amount a label states its values for, for example 60 g, 100 g or 1 serving. Kept unchanged.
public struct LabelBasis: Sendable, Hashable, Codable {
    public let reference: Quantity

    public init(reference: Quantity) throws {
        guard reference.value > 0 else {
            throw UnitError.nonPositiveAmount(reference.value)
        }
        self.reference = reference
    }

    public init(value: Decimal, unit: MeasureUnit) throws {
        try self.init(reference: Quantity(value: value, unit: unit))
    }
}

public struct ConsumedAmount: Sendable, Hashable, Codable {
    public let quantity: Quantity

    public init(value: Decimal, unit: MeasureUnit) throws {
        guard value >= 0 else {
            throw UnitError.negativeAmount(value)
        }
        self.quantity = Quantity(value: value, unit: unit)
    }
}

/// Holds a label basis next to the consumed amount and calculates scaled values from them;
/// neither input is ever overwritten.
public struct ServingCalculation: Sendable, Hashable {
    public let basis: LabelBasis
    public let consumed: ConsumedAmount
    public let density: Decimal?
    public let portion: PortionDefinition?

    public init(
        basis: LabelBasis,
        consumed: ConsumedAmount,
        density: Decimal? = nil,
        portion: PortionDefinition? = nil
    ) {
        self.basis = basis
        self.consumed = consumed
        self.density = density
        self.portion = portion
    }

    public func consumedInBasisUnit() throws -> Quantity {
        try consumed.quantity.converted(to: basis.reference.unit, density: density, portion: portion)
    }

    public func factor() throws -> Decimal {
        let amount = try consumedInBasisUnit()
        return amount.value / basis.reference.value
    }

    /// The label value for the consumed amount. Value states other than `known` pass through unchanged.
    public func scale(_ labelValue: NutrientValue) throws -> NutrientValue {
        let amount = try consumedInBasisUnit()
        guard case .known(let labelAmount, let unit) = labelValue else {
            return labelValue
        }
        return .known(labelAmount * amount.value / basis.reference.value, unit)
    }
}
