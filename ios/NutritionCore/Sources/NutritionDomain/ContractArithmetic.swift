import Foundation

/// The catalog's nutrient arithmetic, as `contracts/nutrients/decimal-rules.md` states it: every amount an exact
/// decimal, a division that does not terminate rounded once to 10 fraction digits (halves away from zero), and any
/// input, product, sum or result beyond 38 significant digits or the exponent range refused rather than cut.
///
/// This is the catalog's arithmetic, run against `contracts/nutrients/golden.v1.json` by the Swift tests as the
/// Python reference evaluator does (NF-03). The journal's own scaling is not this: it keeps the digits Foundation
/// `Decimal` gives (decimal-rules.md, "The journal keeps the digits its arithmetic gives"), so `Quantity` and the
/// journal are left as they are.
public enum ContractArithmetic {
    /// The errors the contract names, spelled as `golden.v1.json` spells them.
    public enum Failure: String, Error, Sendable, CaseIterable {
        case unknownSymbol = "unknown_symbol"
        case dimensionMismatch = "dimension_mismatch"
        case missingDensity = "missing_density"
        case invalidDensity = "invalid_density"
        case missingPortionDefinition = "missing_portion_definition"
        case invalidPortionDefinition = "invalid_portion_definition"
        case incompatibleCountUnits = "incompatible_count_units"
        case internationalUnitNotConvertible = "international_unit_not_convertible"
        case nonPositiveAmount = "non_positive_amount"
        case negativeAmount = "negative_amount"
        case amountOutOfRange = "amount_out_of_range"
    }

    /// A unit the wire carries: its dimension and, where it has one, its exact factor to the dimension's canonical
    /// unit (g, mL, kcal, IU, serving). The table is `contracts/nutrients/registry.v1.json`'s, and a test holds the
    /// two together.
    public struct WireUnit: Sendable, Equatable {
        public let symbol: String
        public let dimension: String
        public let factorToCanonical: String?
    }

    public static let wireUnits: [WireUnit] = [
        WireUnit(symbol: "g", dimension: "mass", factorToCanonical: "1"),
        WireUnit(symbol: "mg", dimension: "mass", factorToCanonical: "0.001"),
        WireUnit(symbol: "mcg", dimension: "mass", factorToCanonical: "0.000001"),
        WireUnit(symbol: "kg", dimension: "mass", factorToCanonical: "1000"),
        WireUnit(symbol: "mL", dimension: "volume", factorToCanonical: "1"),
        WireUnit(symbol: "L", dimension: "volume", factorToCanonical: "1000"),
        WireUnit(symbol: "kcal", dimension: "energy", factorToCanonical: "1"),
        WireUnit(symbol: "IU", dimension: "international_unit", factorToCanonical: "1"),
        WireUnit(symbol: "serving", dimension: "count", factorToCanonical: "1"),
        WireUnit(symbol: "scoop", dimension: "count", factorToCanonical: nil),
        WireUnit(symbol: "tablet", dimension: "count", factorToCanonical: nil),
        WireUnit(symbol: "capsule", dimension: "count", factorToCanonical: nil),
        WireUnit(symbol: "piece", dimension: "count", factorToCanonical: nil),
        WireUnit(symbol: "gummy", dimension: "count", factorToCanonical: nil),
    ]

    /// The mass of one IU, for the one nutrient that states it (vitamin D, 0.025 mcg per IU).
    public static let mcgPerInternationalUnit: [String: String] = ["vitamin_d": "0.025"]

    public static let fractionDigits = 10
    public static let significantDigits = 38
    public static let adjustedExponentLimit = 127

    /// What one count unit holds: `count_unit` in a mass or a volume.
    public struct Portion: Sendable, Equatable {
        public let countUnit: String
        public let amount: String
        public let unit: String

        public init(countUnit: String, amount: String, unit: String) {
            self.countUnit = countUnit
            self.amount = amount
            self.unit = unit
        }
    }

    /// A nutrient value as the contract states it: a state and, when known, an amount and a unit.
    public struct Value: Sendable, Equatable {
        public let state: String
        public let amount: String?
        public let unit: String?

        public init(state: String, amount: String? = nil, unit: String? = nil) {
            self.state = state
            self.amount = amount
            self.unit = unit
        }
    }

    public struct Coverage: Sendable, Equatable {
        public let knownCount: Int
        public let totalCount: Int
        public let hasUnknown: Bool
        public let hasBelowReportingThreshold: Bool
        public var isComplete: Bool { knownCount == totalCount }
    }

    // MARK: - Operations

    /// `amount` in `unit` converted to `target`, as an exact decimal string.
    public static func convert(
        amount: String, unit: String, to target: String, density: String? = nil, portion: Portion? = nil,
        nutrient: String? = nil
    ) throws -> String {
        try decimalString(convert(
            try exact(amount), unit, target, density: density.map(exact), portion: portion, nutrient: nutrient))
    }

    /// A label value stated per `basis`, scaled to the `consumed` amount: value x consumed / basis, multiplied first
    /// and divided once, last. A value that is not known passes through unchanged.
    public static func scale(
        basisAmount: String, basisUnit: String, consumedAmount: String, consumedUnit: String, value: Value,
        density: String? = nil, portion: Portion? = nil
    ) throws -> Value {
        let basis = try exact(basisAmount)
        guard basis.isPositive else { throw Failure.nonPositiveAmount }
        let consumed = try exact(consumedAmount)
        guard !consumed.isNegative else { throw Failure.negativeAmount }
        let consumedInBasis = try convert(
            consumed, consumedUnit, basisUnit, density: density.map(exact), portion: portion, nutrient: nil)
        guard value.state == "known", let stated = value.amount else {
            return Value(state: value.state, unit: value.unit)
        }
        let amount = try exact(stated)
        guard !amount.isNegative else { throw Failure.negativeAmount }
        let scaled = try quotient(bounded(amount * consumedInBasis), basis)
        return Value(state: "known", amount: decimalString(scaled), unit: value.unit)
    }

    /// Sums the known values in `unit` (default: the first known value's unit). Unknown and below-threshold values are
    /// counted in the coverage but not in the total; not-applicable values are left out of both.
    public static func sum(_ values: [Value], unit requested: String? = nil, nutrient: String? = nil) throws
        -> (value: Value, coverage: Coverage)
    {
        var known: [(Rational, String)] = []
        var total = 0
        var hasUnknown = false
        var hasBelow = false
        for value in values {
            switch value.state {
            case "known":
                known.append((try exact(value.amount ?? ""), value.unit ?? ""))
                total += 1
            case "unknown":
                hasUnknown = true
                total += 1
            case "below_reporting_threshold":
                hasBelow = true
                total += 1
            default:
                continue
            }
        }
        let coverage = Coverage(
            knownCount: known.count, totalCount: total, hasUnknown: hasUnknown, hasBelowReportingThreshold: hasBelow)
        guard !known.isEmpty else {
            let state = hasUnknown ? "unknown" : hasBelow ? "below_reporting_threshold"
                : values.isEmpty ? "unknown" : "not_applicable"
            return (Value(state: state), coverage)
        }
        // IU of a nutrient with a fixed mass per IU is restated in mcg before the total's unit is chosen; a sum asked
        // for in IU keeps IU, and a mass is never converted into IU.
        if requested != "IU", let nutrient, mcgPerInternationalUnit[nutrient] != nil {
            known = try known.map { amount, unit in
                unit == "IU" ? (try convert(amount, unit, "mcg", density: nil, portion: nil, nutrient: nutrient), "mcg")
                    : (amount, unit)
            }
        }
        let target = requested ?? known[0].1
        var running = Rational.zero
        for (amount, unit) in known {
            running = try bounded(
                running + convert(amount, unit, target, density: nil, portion: nil, nutrient: nutrient))
        }
        return (Value(state: "known", amount: decimalString(running), unit: target), coverage)
    }

    // MARK: - Steps

    private static func unitEntry(_ symbol: String) throws -> WireUnit {
        guard let entry = wireUnits.first(where: { $0.symbol == symbol }) else { throw Failure.unknownSymbol }
        return entry
    }

    private static func convert(
        _ amount: Rational, _ unit: String, _ target: String, density: Rational?, portion: Portion?,
        nutrient: String?
    ) throws -> Rational {
        let source = try unitEntry(unit)
        let dest = try unitEntry(target)
        guard !amount.isNegative else { throw Failure.negativeAmount }
        if unit == target { return amount }

        if source.dimension == dest.dimension {
            if source.dimension == "count" { throw Failure.incompatibleCountUnits }
            // Both factors are powers of ten: the step is exact, but it can leave the exponent range.
            let canonical = try bounded(amount * exact(source.factorToCanonical ?? "1"))
            return try bounded(canonical / exact(dest.factorToCanonical ?? "1"))
        }
        if source.dimension == "international_unit" || dest.dimension == "international_unit" {
            guard let nutrient, let factor = mcgPerInternationalUnit[nutrient],
                source.dimension == "international_unit", dest.dimension == "mass"
            else { throw Failure.internationalUnitNotConvertible }
            return try convert(bounded(amount * exact(factor)), "mcg", target, density: nil, portion: nil, nutrient: nil)
        }
        let measurable = ["mass", "volume"]
        if source.dimension == "count", measurable.contains(dest.dimension) {
            guard let portion else { throw Failure.missingPortionDefinition }
            let (countUnit, portionAmount, portionUnit) = try validPortion(portion)
            guard countUnit == unit else { throw Failure.missingPortionDefinition }
            return try convert(
                bounded(amount * portionAmount), portionUnit, target, density: density, portion: nil, nutrient: nil)
        }
        if measurable.contains(source.dimension), dest.dimension == "count" {
            guard let portion else { throw Failure.missingPortionDefinition }
            let (countUnit, portionAmount, portionUnit) = try validPortion(portion)
            guard countUnit == target else { throw Failure.missingPortionDefinition }
            return try quotient(
                convert(amount, unit, portionUnit, density: density, portion: nil, nutrient: nil), portionAmount)
        }
        if Set([source.dimension, dest.dimension]) == Set(measurable) {
            guard let density else { throw Failure.missingDensity }
            guard density.isPositive else { throw Failure.invalidDensity }
            // Density is grams per millilitre, applied in the canonical units; then the target's power of ten.
            var canonical = try bounded(amount * exact(source.factorToCanonical ?? "1"))
            canonical = source.dimension == "mass" ? try quotient(canonical, density) : try bounded(canonical * density)
            return try bounded(canonical / exact(dest.factorToCanonical ?? "1"))
        }
        throw Failure.dimensionMismatch
    }

    private static func validPortion(_ portion: Portion) throws -> (String, Rational, String) {
        let count = try unitEntry(portion.countUnit)
        let measure = try unitEntry(portion.unit)
        let amount = try exact(portion.amount)
        guard count.dimension == "count", ["mass", "volume"].contains(measure.dimension), amount.isPositive else {
            throw Failure.invalidPortionDefinition
        }
        return (portion.countUnit, amount, portion.unit)
    }

    // MARK: - Exact decimals

    /// The one place a result may be rounded: a quotient with a finite decimal form is kept whole; one without is
    /// rounded to 10 fraction digits, halves away from zero.
    static func quotient(_ numerator: Rational, _ denominator: Rational) throws -> Rational {
        let value = numerator / denominator
        if value.terminates { return try bounded(value) }
        let scale = BigUInt.power(of: 10, fractionDigits)
        // The exact quotient times 10^10, rounded half away from zero: floor((2n + d) / 2d).
        let shiftedNumerator = value.numerator * scale
        let twice = shiftedNumerator + shiftedNumerator + value.denominator
        let whole = twice.quotientAndRemainder(dividingBy: value.denominator + value.denominator).quotient
        let rounded = try bounded(Rational(negative: false, numerator: whole, denominator: scale))
        return value.isNegative ? rounded.negated : rounded
    }

    /// The longest decimal text that can still be in range once its redundant zeros are dropped: a sign, 128 integer
    /// digits, or a point after 127 leading zeros and then 38 digits. Anything longer is refused before any digit is
    /// parsed, so a long string costs only the one pass that trims it.
    static let longestInRangeText = 170

    /// A text that is not a plain decimal is refused as out of range: it is no amount the contract can hold, and the
    /// contract names no other error for it (its schemas refuse such text before any operation runs).
    static func exact(_ text: String) throws -> Rational {
        guard let trimmed = significantText(text), trimmed.utf8.count <= longestInRangeText else {
            throw Failure.amountOutOfRange
        }
        // The trimmed text is what is parsed, so redundant zeros cost no arithmetic either.
        guard let value = Rational(decimal: (text.first == "-" ? "-" : "") + trimmed) else {
            throw Failure.amountOutOfRange
        }
        return try bounded(value)
    }

    /// The text of a plain decimal without the zeros that do not change its value (leading zeros of the integer part,
    /// trailing zeros of the fraction), so "1." with 200 zeros after it is measured and parsed as "1". Nil when the
    /// text is not a plain decimal: optional sign, digits, and an optional point followed by digits. One pass over
    /// the bytes, so a long text costs no more than reading it.
    static func significantText(_ text: String) -> String? {
        var bytes = Array(text.utf8)
        if bytes.first == UInt8(ascii: "-") { bytes.removeFirst() }
        let point = bytes.firstIndex(of: UInt8(ascii: "."))
        let integerEnd = point ?? bytes.count
        let isDigit: (UInt8) -> Bool = { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        guard integerEnd > 0, bytes[..<integerEnd].allSatisfy(isDigit) else { return nil }
        var end = bytes.count
        if let point {
            guard point + 1 < bytes.count, bytes[(point + 1)...].allSatisfy(isDigit) else { return nil }
            while end > point + 1, bytes[end - 1] == UInt8(ascii: "0") { end -= 1 }
            if end == point + 1 { end = point }
        }
        var start = 0
        while start < integerEnd - 1, bytes[start] == UInt8(ascii: "0") { start += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Refused, never cut: more than 38 significant digits, or a leading digit outside 10^-127 ... 10^127.
    static func bounded(_ value: Rational) throws -> Rational {
        guard value.terminates else { return value }
        guard !value.isZero else { return value }
        let (digits, scale) = value.integerAndScale()
        let text = digits.decimalString
        let significant = text.reversed().drop(while: { $0 == "0" }).count
        guard significant <= significantDigits else { throw Failure.amountOutOfRange }
        let adjusted = text.count - 1 - scale
        guard abs(adjusted) <= adjustedExponentLimit else { throw Failure.amountOutOfRange }
        return value
    }

    /// The plain form the contract uses: no exponent and no trailing zeros.
    static func decimalString(_ value: Rational) -> String {
        let (digits, scale) = value.integerAndScale()
        var text = digits.decimalString
        if scale > 0 {
            if text.count <= scale { text = String(repeating: "0", count: scale - text.count + 1) + text }
            let point = text.index(text.endIndex, offsetBy: -scale)
            text = text[..<point] + "." + text[point...]
        }
        return value.isNegative && !value.isZero ? "-" + text : text
    }
}

// MARK: - Exact rational numbers

/// A rational number with an arbitrary-precision numerator and denominator, always in lowest terms.
struct Rational: Equatable {
    let isNegative: Bool
    let numerator: BigUInt
    let denominator: BigUInt

    static let zero = Rational(negative: false, numerator: BigUInt(0), denominator: BigUInt(1))

    init(negative: Bool, numerator: BigUInt, denominator: BigUInt) {
        let divisor = BigUInt.gcd(numerator, denominator)
        let n = numerator.quotientAndRemainder(dividingBy: divisor).quotient
        let d = denominator.quotientAndRemainder(dividingBy: divisor).quotient
        self.isNegative = negative && !n.isZero
        self.numerator = n
        self.denominator = d
    }

    /// A plain decimal string: optional sign, digits, optional fraction. Anything else is nil.
    init?(decimal text: String) {
        var body = Substring(text)
        var negative = false
        if body.first == "-" {
            negative = true
            body = body.dropFirst()
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigitChar) }),
            parts.count == 1 || !parts[1].isEmpty
        else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard let digits = BigUInt(decimal: parts[0] + fraction) else { return nil }
        self.init(negative: negative, numerator: digits, denominator: BigUInt.power(of: 10, fraction.count))
    }

    var isZero: Bool { numerator.isZero }
    var isPositive: Bool { !isNegative && !isZero }
    var negated: Rational { Rational(negative: !isNegative, numerator: numerator, denominator: denominator) }

    /// Whether the decimal form is finite: the denominator has no prime factors but 2 and 5.
    var terminates: Bool {
        var d = denominator
        for prime in [BigUInt(2), BigUInt(5)] {
            while true {
                let (q, r) = d.quotientAndRemainder(dividingBy: prime)
                guard r.isZero else { break }
                d = q
            }
        }
        return d == BigUInt(1)
    }

    /// For a finite decimal: the integer of its digits and how many of them follow the point.
    func integerAndScale() -> (BigUInt, Int) {
        var n = numerator
        var d = denominator
        var scale = 0
        let ten = BigUInt(10)
        while d != BigUInt(1) {
            n = n * ten
            let g = BigUInt.gcd(n, d)
            n = n.quotientAndRemainder(dividingBy: g).quotient
            d = d.quotientAndRemainder(dividingBy: g).quotient
            scale += 1
        }
        return (n, scale)
    }

    static func * (lhs: Rational, rhs: Rational) -> Rational {
        Rational(
            negative: lhs.isNegative != rhs.isNegative, numerator: lhs.numerator * rhs.numerator,
            denominator: lhs.denominator * rhs.denominator)
    }

    static func / (lhs: Rational, rhs: Rational) -> Rational {
        Rational(
            negative: lhs.isNegative != rhs.isNegative, numerator: lhs.numerator * rhs.denominator,
            denominator: lhs.denominator * rhs.numerator)
    }

    /// Addition of two values of the same sign, the only case a sum of amounts that are never negative needs.
    static func + (lhs: Rational, rhs: Rational) -> Rational {
        precondition(lhs.isNegative == rhs.isNegative || lhs.isZero || rhs.isZero)
        return Rational(
            negative: lhs.isNegative || rhs.isNegative,
            numerator: lhs.numerator * rhs.denominator + rhs.numerator * lhs.denominator,
            denominator: lhs.denominator * rhs.denominator)
    }
}

private extension Character {
    var isASCIIDigitChar: Bool { ("0"..."9").contains(self) }
}

// MARK: - Arbitrary-precision unsigned integers

/// A minimal unsigned integer of any size, in base 2^32 limbs, least significant first. It has the operations the
/// contract arithmetic needs and no more.
struct BigUInt: Equatable, Comparable {
    private(set) var limbs: [UInt32]

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init?(decimal text: some StringProtocol) {
        guard !text.isEmpty else { return nil }
        var value = BigUInt(0)
        let ten = BigUInt(10)
        for character in text {
            guard let digit = character.wholeNumberValue, character.isASCII else { return nil }
            value = value * ten + BigUInt(UInt64(digit))
        }
        self = value
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    static func power(of base: UInt64, _ exponent: Int) -> BigUInt {
        var result = BigUInt(1)
        let factor = BigUInt(base)
        for _ in 0..<max(exponent, 0) { result = result * factor }
        return result
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        var carry: UInt64 = 0
        for index in 0..<max(lhs.limbs.count, rhs.limbs.count) {
            let sum = UInt64(index < lhs.limbs.count ? lhs.limbs[index] : 0)
                + UInt64(index < rhs.limbs.count ? rhs.limbs[index] : 0) + carry
            result.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry != 0 { result.append(UInt32(carry)) }
        return BigUInt(limbs: result)
    }

    /// `lhs - rhs`, for `lhs >= rhs`.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(!(lhs < rhs))
        var result: [UInt32] = []
        var borrow: Int64 = 0
        for index in 0..<lhs.limbs.count {
            var difference = Int64(lhs.limbs[index]) - Int64(index < rhs.limbs.count ? rhs.limbs[index] : 0) - borrow
            if difference < 0 {
                difference += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt32(difference))
        }
        return BigUInt(limbs: result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt(0) }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.limbs.count {
                let product = UInt64(lhs.limbs[i]) * UInt64(rhs.limbs[j]) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            var k = i + rhs.limbs.count
            while carry != 0 {
                let sum = UInt64(result[k]) + carry
                result[k] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                k += 1
            }
        }
        return BigUInt(limbs: result)
    }

    private var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    private func bit(_ index: Int) -> Bool {
        let limb = index / 32
        return limb < limbs.count && (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    private func shiftedLeftByOne(settingLowBit low: Bool) -> BigUInt {
        var result: [UInt32] = []
        var carry: UInt32 = low ? 1 : 0
        for limb in limbs {
            result.append((limb << 1) | carry)
            carry = limb >> 31
        }
        if carry != 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }

    /// Long division, one bit at a time: slow, but exact, and the contract's numbers are short.
    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "division by zero")
        guard !(self < divisor) else { return (BigUInt(0), self) }
        var quotientLimbs = [UInt32](repeating: 0, count: limbs.count)
        var remainder = BigUInt(0)
        for index in stride(from: bitWidth - 1, through: 0, by: -1) {
            remainder = remainder.shiftedLeftByOne(settingLowBit: bit(index))
            if !(remainder < divisor) {
                remainder = remainder - divisor
                quotientLimbs[index / 32] |= 1 << UInt32(index % 32)
            }
        }
        return (BigUInt(limbs: quotientLimbs), remainder)
    }

    static func gcd(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var (x, y) = (a, b)
        while !y.isZero { (x, y) = (y, x.quotientAndRemainder(dividingBy: y).remainder) }
        return x.isZero ? BigUInt(1) : x
    }

    var decimalString: String {
        guard !isZero else { return "0" }
        var chunks: [String] = []
        var value = self
        let billion = BigUInt(1_000_000_000)
        while !value.isZero {
            let (q, r) = value.quotientAndRemainder(dividingBy: billion)
            let chunk = String(r.limbs.first ?? 0)
            chunks.append(q.isZero ? chunk : String(repeating: "0", count: 9 - chunk.count) + chunk)
            value = q
        }
        return chunks.reversed().joined()
    }
}
