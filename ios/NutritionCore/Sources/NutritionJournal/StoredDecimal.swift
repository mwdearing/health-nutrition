import Foundation
import NutritionDomain

/// Keeps a value the journal writes one it can read back.
///
/// A 128-bit `Decimal` holds 39 significant digits when they start low, and `DecimalText` reads back at most
/// 38. A value scaled by a factor that does not terminate can land on 39: (709.7647095 + 236.5882365) / 710
/// of 1 g is 1.33289147323943661971830985915492957746 g. Written as it is, that value came back as nothing at
/// all, so the nutrient vanished from the entry. Such a value is rounded, half away from zero, to 38
/// significant digits; every other value is kept exactly as it is.
public enum StoredDecimal {
    /// The most significant digits `DecimalText` reads back.
    static let maximumSignificantDigits = 38

    /// `value`, or that value at 38 significant digits when `DecimalText` could not read it back.
    public static func storable(_ value: Decimal) -> Decimal {
        guard !value.isNaN, !readsBack(value) else { return value }
        var fractionDigits = maximumSignificantDigits - 1 - leadingExponent(of: DecimalText.encode(value.magnitude))
        var rounded = DisplayRounding.rounded(value, fractionDigits: fractionDigits)
        // Rounding up can carry into a new leading digit (9.99... to 10), which leaves room for one fewer.
        while !readsBack(rounded), fractionDigits > -128 {
            fractionDigits -= 1
            rounded = DisplayRounding.rounded(value, fractionDigits: fractionDigits)
        }
        return rounded
    }

    /// A known value made storable; every other state is kept as it is.
    public static func storable(_ value: NutrientValue) -> NutrientValue {
        guard case .known(let amount, let unit) = value else { return value }
        return .known(storable(amount), unit)
    }

    public static func storable(_ values: [String: NutrientValue]) -> [String: NutrientValue] {
        values.mapValues { storable($0) }
    }

    /// A value the store wrote as text: what `DecimalText` reads back, or, for a row written before the
    /// journal kept its values readable, a value the encoder wrote with one digit more, rounded as
    /// `storable` rounds it. Text in any other form stays refused.
    static func readBack(_ text: String) -> Decimal? {
        if let value = DecimalText.decode(text) { return value }
        guard DecimalText.isValidDecimalText(text),
              let value = Decimal(string: text, locale: DecimalText.locale), !value.isNaN,
              DecimalText.encode(value) == text
        else { return nil }
        return storable(value)
    }

    private static func readsBack(_ value: Decimal) -> Bool {
        DecimalText.decode(DecimalText.encode(value)) != nil
    }

    /// The power of ten of the leading digit of plain decimal text: 2 for "123.4", -3 for "0.00123".
    private static func leadingExponent(of text: String) -> Int {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts[0]
        if let first = integer.firstIndex(where: { $0 != "0" }) {
            return integer.distance(from: first, to: integer.endIndex) - 1
        }
        let fraction = parts.count > 1 ? parts[1] : ""
        return -(fraction.prefix { $0 == "0" }.count + 1)
    }
}
