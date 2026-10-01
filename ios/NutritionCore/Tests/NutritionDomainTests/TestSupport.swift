import XCTest
@testable import NutritionDomain

private let posix = Locale(identifier: "en_US_POSIX")

func dec(_ text: String) throws -> Decimal {
    try XCTUnwrap(Decimal(string: text, locale: posix), "not a decimal literal: \(text)")
}

func qty(_ text: String, _ unit: MeasureUnit) throws -> Quantity {
    Quantity(value: try dec(text), unit: unit)
}

func known(_ text: String, _ unit: MeasureUnit) throws -> NutrientValue {
    NutrientValue.known(try dec(text), unit)
}
