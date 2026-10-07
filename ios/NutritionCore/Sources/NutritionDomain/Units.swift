import Foundation

public enum UnitDimension: String, Sendable, Hashable, Codable, CaseIterable {
    case mass
    case volume
    case energy
    case count
    case internationalUnit
}

public enum UnitError: Error, Sendable, Equatable {
    case unknownSymbol(String)
    case dimensionMismatch(from: MeasureUnit, to: MeasureUnit)
    case missingDensity(from: MeasureUnit, to: MeasureUnit)
    case invalidDensity(Decimal)
    case missingPortionDefinition(from: MeasureUnit, to: MeasureUnit)
    case invalidPortionDefinition(countUnit: MeasureUnit, quantity: Quantity)
    case internationalUnitNotConvertible(from: MeasureUnit, to: MeasureUnit)
    case incompatibleCountUnits(from: MeasureUnit, to: MeasureUnit)
    case nonPositiveAmount(Decimal)
    case negativeAmount(Decimal)
}

private func power10(_ exponent: Int) -> Decimal {
    Decimal(sign: .plus, exponent: exponent, significand: 1)
}

/// A unit whose factor is written out in full rather than as a power of ten, and whose reciprocal
/// does not terminate: one ounce is exactly 28.349523125 g, but 1/28.349523125 repeats forever, so
/// there is no decimal that can be stored for it.
///
/// So none is stored. Converting INTO this unit divides by `toBase` and rounds the quotient to
/// `UnitRegistry.reciprocalFractionDigits` fraction digits, which is the precision the registry
/// documents and the tests assert. Converting out of it is the exact multiplication by `toBase`.
private func repeatingReciprocalUnit(symbol: String, dimension: UnitDimension, _ text: String) -> MeasureUnit {
    let toBase = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    return MeasureUnit(symbol: symbol, dimension: dimension, toBase: toBase, fromBase: nil)
}

/// A unit from the canonical registry.
///
/// Most factors are exact powers of ten, so `fromBase` is their exact reciprocal and a conversion is
/// two multiplications, never a division of the amount being converted. The two ounces have exact
/// factors whose reciprocals repeat, so they carry no reciprocal at all: `fromBase` is nil and a
/// conversion into them divides by `toBase` and rounds the quotient to the documented precision.
/// That is a stated rounding, not a claim of exactness.
public struct MeasureUnit: Sendable, Hashable, Codable {
    public let symbol: String
    public let dimension: UnitDimension
    let toBase: Decimal
    /// The exact reciprocal of `toBase`, or nil when the reciprocal repeats and cannot be a decimal.
    let fromBase: Decimal?

    init(symbol: String, dimension: UnitDimension, toBase: Decimal, fromBase: Decimal?) {
        self.symbol = symbol
        self.dimension = dimension
        self.toBase = toBase
        self.fromBase = fromBase
    }

    public init(symbol: String) throws {
        self = try UnitRegistry.unit(for: symbol)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let symbol = try container.decode(String.self)
        self = try UnitRegistry.unit(for: symbol)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(symbol)
    }
}

extension MeasureUnit {
    /// An amount already in the base unit, expressed in this unit.
    ///
    /// Exact for the units whose factor is a power of ten, and for the ounces in the other direction:
    /// multiplying by an exact factor is exact. A division is used only where the reciprocal repeats,
    /// and the quotient is rounded to `UnitRegistry.reciprocalFractionDigits` fraction digits, so
    /// this is the one place the documented precision is applied.
    func amount(fromBase baseAmount: Decimal) -> Decimal {
        guard let fromBase else {
            return DisplayRounding.rounded(baseAmount / toBase, fractionDigits: UnitRegistry.reciprocalFractionDigits)
        }
        return baseAmount * fromBase
    }
}

extension MeasureUnit {
    public static let g = MeasureUnit(symbol: "g", dimension: .mass, toBase: power10(0), fromBase: power10(0))
    public static let mg = MeasureUnit(symbol: "mg", dimension: .mass, toBase: power10(-3), fromBase: power10(3))
    public static let mcg = MeasureUnit(symbol: "mcg", dimension: .mass, toBase: power10(-6), fromBase: power10(6))
    public static let kg = MeasureUnit(symbol: "kg", dimension: .mass, toBase: power10(3), fromBase: power10(-3))
    /// One avoirdupois ounce: exactly 28.349523125 g. A weight, so it never converts to a volume without
    /// a density, exactly like `g` itself. Converting into it divides and rounds to the documented
    /// precision, so ounces are exact out of grams and rounded into them.
    public static let oz = repeatingReciprocalUnit(symbol: "oz", dimension: .mass, "28.349523125")
    public static let mL = MeasureUnit(symbol: "mL", dimension: .volume, toBase: power10(0), fromBase: power10(0))
    public static let L = MeasureUnit(symbol: "L", dimension: .volume, toBase: power10(3), fromBase: power10(-3))
    /// One US fluid ounce: exactly 29.5735295625 mL. A distinct symbol from `oz`, so a weight is never
    /// read as a measure. Rounded into from millilitres, exactly like `oz` is from grams.
    public static let flOz = repeatingReciprocalUnit(symbol: "fl oz", dimension: .volume, "29.5735295625")
    public static let kcal = MeasureUnit(symbol: "kcal", dimension: .energy, toBase: power10(0), fromBase: power10(0))
    public static let serving = MeasureUnit(symbol: "serving", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let scoop = MeasureUnit(symbol: "scoop", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let tablet = MeasureUnit(symbol: "tablet", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let capsule = MeasureUnit(symbol: "capsule", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let iu = MeasureUnit(symbol: "IU", dimension: .internationalUnit, toBase: power10(0), fromBase: power10(0))
}

/// The closed set of units the app stores, offers and converts between.
///
/// One avoirdupois ounce (28.349523125 g) and one US fluid ounce (29.5735295625 mL) are exact in the
/// base unit, but their reciprocals repeat forever, so no reciprocal is stored for either. A
/// conversion INTO an ounce therefore divides by the exact factor and rounds the quotient, plainly,
/// to `reciprocalFractionDigits` fraction digits. Ten digits is far past anything a person reads and
/// far enough below the factor's own precision that a round trip is exact at the six digits the
/// domain tests assert; it is a documented rounding, not an exactness claim.
public enum UnitRegistry: Sendable {
    /// Fraction digits a conversion into `oz` or `fl oz` is rounded to.
    public static let reciprocalFractionDigits = 10

    public static let all: [MeasureUnit] = [
        .g, .mg, .mcg, .kg, .oz, .mL, .L, .flOz, .kcal, .serving, .scoop, .tablet, .capsule, .iu,
    ]

    public static func unit(for symbol: String) throws -> MeasureUnit {
        guard let found = all.first(where: { $0.symbol == symbol }) else {
            throw UnitError.unknownSymbol(symbol)
        }
        return found
    }

    public static func units(in dimension: UnitDimension) -> [MeasureUnit] {
        all.filter { $0.dimension == dimension }
    }
}
