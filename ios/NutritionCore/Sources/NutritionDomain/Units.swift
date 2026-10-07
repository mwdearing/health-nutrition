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

/// A unit whose factor is written out in full rather than as a power of ten, with its reciprocal
/// computed to the full precision a `Decimal` carries.
///
/// Both directions are then exact decimals, so converting stays two multiplications: one ounce is
/// exactly 28.349523125 g, and that many grams is exactly one ounce again.
private func fixedFactorUnit(symbol: String, dimension: UnitDimension, _ text: String) -> MeasureUnit {
    let toBase = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    return MeasureUnit(symbol: symbol, dimension: dimension, toBase: toBase, fromBase: 1 / toBase)
}

/// A unit from the canonical registry.
///
/// `toBase` and `fromBase` are exact decimals, so a conversion is two multiplications and never a
/// division of the amount being converted. Most factors are exact powers of ten; the US customary ones
/// are exact decimals of their own, and their reciprocal is carried to full decimal precision, so a
/// round trip through the base unit is exact for the values a person enters.
public struct MeasureUnit: Sendable, Hashable, Codable {
    public let symbol: String
    public let dimension: UnitDimension
    let toBase: Decimal
    let fromBase: Decimal

    init(symbol: String, dimension: UnitDimension, toBase: Decimal, fromBase: Decimal) {
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
    public static let g = MeasureUnit(symbol: "g", dimension: .mass, toBase: power10(0), fromBase: power10(0))
    public static let mg = MeasureUnit(symbol: "mg", dimension: .mass, toBase: power10(-3), fromBase: power10(3))
    public static let mcg = MeasureUnit(symbol: "mcg", dimension: .mass, toBase: power10(-6), fromBase: power10(6))
    public static let kg = MeasureUnit(symbol: "kg", dimension: .mass, toBase: power10(3), fromBase: power10(-3))
    /// One avoirdupois ounce: exactly 28.349523125 g. A weight, so it never converts to a volume without
    /// a density, exactly like `g` itself.
    public static let oz = fixedFactorUnit(symbol: "oz", dimension: .mass, "28.349523125")
    public static let mL = MeasureUnit(symbol: "mL", dimension: .volume, toBase: power10(0), fromBase: power10(0))
    public static let L = MeasureUnit(symbol: "L", dimension: .volume, toBase: power10(3), fromBase: power10(-3))
    /// One US fluid ounce: exactly 29.5735295625 mL. A distinct symbol from `oz`, so a weight is never
    /// read as a measure.
    public static let flOz = fixedFactorUnit(symbol: "fl oz", dimension: .volume, "29.5735295625")
    public static let kcal = MeasureUnit(symbol: "kcal", dimension: .energy, toBase: power10(0), fromBase: power10(0))
    public static let serving = MeasureUnit(symbol: "serving", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let scoop = MeasureUnit(symbol: "scoop", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let tablet = MeasureUnit(symbol: "tablet", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let capsule = MeasureUnit(symbol: "capsule", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let iu = MeasureUnit(symbol: "IU", dimension: .internationalUnit, toBase: power10(0), fromBase: power10(0))
}

public enum UnitRegistry: Sendable {
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
