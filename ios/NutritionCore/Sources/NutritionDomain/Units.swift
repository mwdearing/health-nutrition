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

/// A unit from the canonical registry. Factors are exact powers of ten, so conversion never uses division.
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
    public static let mL = MeasureUnit(symbol: "mL", dimension: .volume, toBase: power10(0), fromBase: power10(0))
    public static let L = MeasureUnit(symbol: "L", dimension: .volume, toBase: power10(3), fromBase: power10(-3))
    public static let kcal = MeasureUnit(symbol: "kcal", dimension: .energy, toBase: power10(0), fromBase: power10(0))
    public static let serving = MeasureUnit(symbol: "serving", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let scoop = MeasureUnit(symbol: "scoop", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let tablet = MeasureUnit(symbol: "tablet", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let capsule = MeasureUnit(symbol: "capsule", dimension: .count, toBase: power10(0), fromBase: power10(0))
    public static let iu = MeasureUnit(symbol: "IU", dimension: .internationalUnit, toBase: power10(0), fromBase: power10(0))
}

public enum UnitRegistry: Sendable {
    public static let all: [MeasureUnit] = [
        .g, .mg, .mcg, .kg, .mL, .L, .kcal, .serving, .scoop, .tablet, .capsule, .iu,
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
