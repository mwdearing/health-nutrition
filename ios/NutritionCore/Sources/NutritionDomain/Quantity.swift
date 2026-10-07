import Foundation

public struct Quantity: Sendable, Hashable, Codable {
    public let value: Decimal
    public let unit: MeasureUnit

    public init(value: Decimal, unit: MeasureUnit) {
        self.value = value
        self.unit = unit
    }

    public func scaled(by factor: Decimal) -> Quantity {
        Quantity(value: value * factor, unit: unit)
    }

    /// Sum in this quantity's unit; the dimensions must match.
    public func adding(_ other: Quantity) throws -> Quantity {
        guard unit.dimension == other.unit.dimension else {
            throw UnitError.dimensionMismatch(from: other.unit, to: unit)
        }
        let converted = try other.converted(to: unit)
        return Quantity(value: value + converted.value, unit: unit)
    }

    public func rounded(fractionDigits: Int) -> Quantity {
        Quantity(value: DisplayRounding.rounded(value, fractionDigits: fractionDigits), unit: unit)
    }

    /// Converts within a dimension exactly. Mass and volume need a density (g per mL);
    /// count units need a portion definition; international units never convert.
    public func converted(
        to target: MeasureUnit,
        density: Decimal? = nil,
        portion: PortionDefinition? = nil
    ) throws -> Quantity {
        if unit == target {
            return self
        }
        let sourceDimension = unit.dimension
        let targetDimension = target.dimension

        if sourceDimension == targetDimension {
            switch sourceDimension {
            case .count:
                throw UnitError.incompatibleCountUnits(from: unit, to: target)
            case .mass, .volume, .energy, .internationalUnit:
                return Quantity(value: target.amount(fromBase: value * unit.toBase), unit: target)
            }
        }

        if sourceDimension == .internationalUnit || targetDimension == .internationalUnit {
            throw UnitError.internationalUnitNotConvertible(from: unit, to: target)
        }

        switch (sourceDimension, targetDimension) {
        case (.count, .mass), (.count, .volume):
            guard let portion, portion.countUnit == unit else {
                throw UnitError.missingPortionDefinition(from: unit, to: target)
            }
            let inPortionUnit = Quantity(value: value * portion.quantity.value, unit: portion.quantity.unit)
            return try inPortionUnit.converted(to: target, density: density)
        case (.mass, .count), (.volume, .count):
            guard let portion, portion.countUnit == target else {
                throw UnitError.missingPortionDefinition(from: unit, to: target)
            }
            let inPortionUnit = try converted(to: portion.quantity.unit, density: density)
            return Quantity(value: inPortionUnit.value / portion.quantity.value, unit: target)
        case (.mass, .volume):
            let gramsPerMilliliter = try validDensity(density, target: target)
            let milliliters = value * unit.toBase / gramsPerMilliliter
            return Quantity(value: target.amount(fromBase: milliliters), unit: target)
        case (.volume, .mass):
            let gramsPerMilliliter = try validDensity(density, target: target)
            let grams = value * unit.toBase * gramsPerMilliliter
            return Quantity(value: target.amount(fromBase: grams), unit: target)
        default:
            throw UnitError.dimensionMismatch(from: unit, to: target)
        }
    }

    private func validDensity(_ density: Decimal?, target: MeasureUnit) throws -> Decimal {
        guard let density else {
            throw UnitError.missingDensity(from: unit, to: target)
        }
        guard density > 0 else {
            throw UnitError.invalidDensity(density)
        }
        return density
    }
}

/// Defines what one count unit weighs or measures, for example 1 scoop = 5 g.
public struct PortionDefinition: Sendable, Hashable, Codable {
    public let countUnit: MeasureUnit
    public let quantity: Quantity

    public init(countUnit: MeasureUnit, quantity: Quantity) throws {
        let measurable = quantity.unit.dimension == .mass || quantity.unit.dimension == .volume
        guard countUnit.dimension == .count, measurable, quantity.value > 0 else {
            throw UnitError.invalidPortionDefinition(countUnit: countUnit, quantity: quantity)
        }
        self.countUnit = countUnit
        self.quantity = quantity
    }
}

public enum DisplayRounding: Sendable {
    /// Plain rounding to the given number of fraction digits. Returns a new value; call it only at display time.
    public static func rounded(_ value: Decimal, fractionDigits: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, fractionDigits, .plain)
        return result
    }
}
