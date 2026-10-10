import Foundation

public enum NutrientValue: Sendable, Hashable, Codable {
    case known(Decimal, MeasureUnit)
    case unknown
    case notApplicable
    case belowReportingThreshold(MeasureUnit?)

    public var quantity: Quantity? {
        guard case .known(let amount, let unit) = self else {
            return nil
        }
        return Quantity(value: amount, unit: unit)
    }

    /// Whether this value states an amount, as opposed to unknown or a bound. A row the parser did
    /// not read states no amount, so it is not a row that was captured with a value.
    public var isKnown: Bool {
        if case .known = self { return true }
        return false
    }

    public func scaled(by factor: Decimal) -> NutrientValue {
        guard case .known(let amount, let unit) = self else {
            return self
        }
        return .known(amount * factor, unit)
    }

    public func converted(
        to target: MeasureUnit,
        density: Decimal? = nil,
        portion: PortionDefinition? = nil
    ) throws -> NutrientValue {
        switch self {
        case .known(let amount, let unit):
            let result = try Quantity(value: amount, unit: unit).converted(to: target, density: density, portion: portion)
            return .known(result.value, result.unit)
        case .unknown:
            return .unknown
        case .notApplicable:
            return .notApplicable
        case .belowReportingThreshold(let unit):
            guard let unit else {
                return .belowReportingThreshold(nil)
            }
            _ = try Quantity(value: 1, unit: unit).converted(to: target, density: density, portion: portion)
            return .belowReportingThreshold(target)
        }
    }

    /// For display only: returns a rounded copy and leaves the stored value as it is.
    public func rounded(fractionDigits: Int) -> NutrientValue {
        guard case .known(let amount, let unit) = self else {
            return self
        }
        return .known(DisplayRounding.rounded(amount, fractionDigits: fractionDigits), unit)
    }
}

public struct Coverage: Sendable, Hashable {
    public let knownCount: Int
    public let totalCount: Int
    public let hasBelowReportingThreshold: Bool
    public let hasUnknown: Bool

    public init(knownCount: Int, totalCount: Int, hasBelowReportingThreshold: Bool, hasUnknown: Bool) {
        self.knownCount = knownCount
        self.totalCount = totalCount
        self.hasBelowReportingThreshold = hasBelowReportingThreshold
        self.hasUnknown = hasUnknown
    }

    public var isComplete: Bool {
        knownCount == totalCount
    }
}

public struct NutrientTotal: Sendable, Hashable {
    public let value: NutrientValue
    public let coverage: Coverage

    public init(value: NutrientValue, coverage: Coverage) {
        self.value = value
        self.coverage = coverage
    }

    /// Sums the known values in `unit` (default: the first known value's unit). Unknown and below-threshold
    /// values are skipped but reported in the coverage; not-applicable values are left out of the counts.
    ///
    /// `expecting` is the unit the nutrient is read in. Every known value must share its dimension, even
    /// when it is the only one, and a value that does not throws `UnitError.dimensionMismatch`. It does not
    /// choose the total's unit, so a compatible total keeps the unit it was read in.
    public static func sum(
        _ values: [NutrientValue], in unit: MeasureUnit? = nil, expecting expected: MeasureUnit? = nil
    ) throws -> NutrientTotal {
        var knownQuantities: [Quantity] = []
        var totalCount = 0
        var hasUnknown = false
        var hasBelow = false

        for value in values {
            switch value {
            case .known(let amount, let amountUnit):
                let quantity = Quantity(value: amount, unit: amountUnit)
                if let expected, amountUnit.dimension != expected.dimension {
                    throw UnitError.dimensionMismatch(from: amountUnit, to: expected)
                }
                knownQuantities.append(quantity)
                totalCount += 1
            case .unknown:
                hasUnknown = true
                totalCount += 1
            case .belowReportingThreshold:
                hasBelow = true
                totalCount += 1
            case .notApplicable:
                break
            }
        }

        let coverage = Coverage(
            knownCount: knownQuantities.count,
            totalCount: totalCount,
            hasBelowReportingThreshold: hasBelow,
            hasUnknown: hasUnknown
        )

        guard let first = knownQuantities.first else {
            if hasUnknown {
                return NutrientTotal(value: .unknown, coverage: coverage)
            }
            if hasBelow {
                return NutrientTotal(value: .belowReportingThreshold(nil), coverage: coverage)
            }
            let state: NutrientValue = values.isEmpty ? .unknown : .notApplicable
            return NutrientTotal(value: state, coverage: coverage)
        }

        let target = unit ?? first.unit
        var sum = Decimal(0)
        for quantity in knownQuantities {
            guard quantity.unit.dimension == target.dimension else {
                throw UnitError.dimensionMismatch(from: quantity.unit, to: target)
            }
            let converted = try quantity.converted(to: target)
            sum += converted.value
        }
        return NutrientTotal(value: .known(sum, target), coverage: coverage)
    }
}
