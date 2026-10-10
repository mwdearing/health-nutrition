import Foundation
import NutritionDomain
import NutritionJournal

/// Which units the Add-intake picker offers, and in what order.
///
/// This is about what a person is OFFERED. A unit chosen here decides the unit an amount is read in;
/// the ounces and the typed volumes are converted to the metric unit they stand for before anything is
/// stored, so changing this list never rewrites anything already logged.
public enum UnitSelection {
    /// The volume measures a person types as input only: a cup, a tablespoon and a teaspoon. They are never
    /// stored, and the recipe editor and the goals screen do not offer them.
    public static let typedVolumes: [MeasureUnit] = [.cup, .tablespoon, .teaspoon]

    /// Every unit the picker offers under `system`, the system's own units first.
    public static func offered(for system: UnitSystem) -> [MeasureUnit] {
        let preferred = preferred(for: system)
        let rest = UnitRegistry.all.filter { unit in !preferred.contains(unit) }
        return preferred + rest
    }

    /// The units a system puts first: the whole list for metric, and for US the two ounces and the three
    /// typed volume measures.
    public static func preferred(for system: UnitSystem) -> [MeasureUnit] {
        switch system {
        case .metric: return UnitRegistry.all
        case .usCustomary: return [.oz, .flOz] + typedVolumes
        }
    }
}

/// A stored amount shown in the unit the reader chose. Never written back: a stored value keeps the
/// unit it was entered in.
public struct DisplayAmount: Equatable {
    public let amount: Decimal
    public let unit: MeasureUnit
    /// True when the amount is real but below the smallest figure the shown unit can carry, so it is
    /// read as "less than" rather than rounded to a zero.
    public let isBelowSmallest: Bool
    private let groupsWholeAmount: Bool
    private let smallestAmount: Decimal

    public init(
        amount: Decimal, unit: MeasureUnit, isBelowSmallest: Bool = false,
        groupsWholeAmount: Bool = false, smallestAmount: Decimal = AmountDisplay.smallestShown
    ) {
        self.amount = amount
        self.unit = unit
        self.isBelowSmallest = isBelowSmallest
        self.groupsWholeAmount = groupsWholeAmount
        self.smallestAmount = smallestAmount
    }

    /// The amount and its symbol, as one line of text. An amount too small to name says so instead of
    /// showing a zero, because a non-zero stored amount must never read as none of it.
    public var text: String {
        guard isBelowSmallest else {
            return "\(self.numberText) \(unit.symbol)"
        }
        return "< \(DecimalFormatting.text(self.smallestAmount)) \(unit.symbol)"
    }

    /// The figures alone, for a sentence that spells the unit out in words.
    ///
    /// Built from the same bound as `text`, because a screen reader hearing "0 fluid ounces" for an
    /// amount that is not zero is the same wrong figure in a different voice.
    public var spokenAmount: String {
        guard isBelowSmallest else { return self.numberText }
        return "less than \(DecimalFormatting.text(self.smallestAmount))"
    }

    private var numberText: String {
        guard self.groupsWholeAmount else { return DecimalFormatting.text(self.amount) }
        return self.amount.formatted(
            .number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0)))
    }
}

/// How a stored amount is shown under a unit system.
///
/// Metric shows what is stored: the stored unit is shown unchanged, so 10 mg reads "10 mg" and is
/// never scaled into grams. The US system converts only the two base-scale units a customary kitchen
/// measure uses, grams and kilograms into ounces and milliliters and liters into fluid ounces.
/// Milligrams and micrograms are too small to be anyone's kitchen measure, and energy, counts and
/// international units have no customary counterpart here, so all of them are shown as stored.
public enum AmountDisplay {
    /// Fraction digits a converted amount carries at or above ten. A converted ounce is a kitchen
    /// measure, and a hundredth of one says nothing the reader can act on.
    public static let largeFractionDigits = 1
    /// Fraction digits a converted amount carries between one and ten.
    public static let mediumFractionDigits = 2
    /// The most fraction digits a converted amount carries below one, so a small ounce still says
    /// something the reader can act on.
    public static let smallFractionDigits = 4
    /// The smallest converted amount shown as a number rather than as "less than".
    public static let smallestShown = Decimal(string: "0.0001", locale: AmountParser.locale)!

    /// The mass unit a system shows weights in. Only the US system has one, because a metric reader is
    /// shown what is stored.
    public static func massUnit(for system: UnitSystem) -> MeasureUnit {
        system == .usCustomary ? .oz : .g
    }

    /// The volume unit a system shows volumes in, for the same reason as `massUnit(for:)`.
    public static func volumeUnit(for system: UnitSystem) -> MeasureUnit {
        system == .usCustomary ? .flOz : .mL
    }

    /// The unit a stored unit is shown in. Metric shows the stored unit itself; the US system converts
    /// grams and kilograms to ounces and milliliters and liters to fluid ounces, and leaves every
    /// other stored unit alone.
    public static func displayUnit(for stored: MeasureUnit, system: UnitSystem) -> MeasureUnit {
        guard system == .usCustomary else { return stored }
        switch stored {
        case .g, .kg: return massUnit(for: system)
        case .mL, .L: return volumeUnit(for: system)
        default: return stored
        }
    }

    /// The fraction digits a converted amount is shown with: one at or above ten, two above one, and
    /// below one enough of them to carry the figure, up to four.
    ///
    /// Trailing zeros are dropped by choosing the fewest digits that still hold the same value, so
    /// 8.5 fl oz does not read as 8.4500.
    public static func fractionDigits(for amount: Decimal) -> Int {
        let magnitude = abs(amount)
        if magnitude >= 10 { return largeFractionDigits }
        if magnitude >= 1 { return mediumFractionDigits }
        let rounded = DisplayRounding.rounded(amount, fractionDigits: smallFractionDigits)
        for digits in stride(from: smallFractionDigits - 1, through: 0, by: -1)
        where DisplayRounding.rounded(amount, fractionDigits: digits) == rounded {
            return digits
        }
        return smallFractionDigits
    }

    /// The stored amount, converted and rounded for showing. A value that is not a number, or an
    /// amount that cannot be converted, is shown as stored rather than as a wrong figure.
    public static func display(_ amount: Decimal, unit: MeasureUnit, system: UnitSystem) -> DisplayAmount {
        guard !amount.isNaN else { return DisplayAmount(amount: amount, unit: unit) }
        let target = displayUnit(for: unit, system: system)
        guard target != unit else { return DisplayAmount(amount: amount, unit: unit) }
        guard let converted = try? Quantity(value: amount, unit: unit).converted(to: target),
              !converted.value.isNaN
        else {
            return DisplayAmount(amount: amount, unit: unit)
        }
        let rounded = DisplayRounding.rounded(
            converted.value, fractionDigits: fractionDigits(for: converted.value))
        // A real amount must never be shown as none of it, so one too small for the unit's digits is
        // shown as a bound instead. The test is on the converted figure itself rather than on what
        // survived rounding.
        let tooSmall = converted.value != 0 && abs(rounded) < smallestShown
        return DisplayAmount(amount: rounded, unit: target, isBelowSmallest: tooSmall)
    }

    /// Water cards and goals show whole, grouped mL or the existing rounded fl oz.
    public static func water(
        _ amount: Decimal, unit: MeasureUnit = .mL, system: UnitSystem
    ) -> DisplayAmount {
        guard let milliliters = try? Quantity(value: amount, unit: unit).converted(to: .mL).value
        else { return display(amount, unit: unit, system: system) }
        let shown = display(milliliters, unit: .mL, system: system)
        let rounded = system == .metric
            ? DisplayRounding.rounded(shown.amount, fractionDigits: 0) : shown.amount
        return DisplayAmount(
            amount: rounded, unit: shown.unit,
            isBelowSmallest: shown.isBelowSmallest || (milliliters > 0 && rounded == 0),
            groupsWholeAmount: system == .metric,
            smallestAmount: system == .metric ? 1 : smallestShown)
    }

    /// The stored component's amount, shown under `system`.
    public static func display(_ component: IntakeComponent, system: UnitSystem) -> DisplayAmount {
        display(component.amount, unit: component.unit, system: system)
    }

    /// How a unit is read aloud. Spelled out rather than spoken as a symbol, because a VoiceOver user
    /// hearing "fl oz" gets no more from it than from "mL".
    public static func spokenName(for unit: MeasureUnit) -> String {
        switch unit {
        case .g: return "grams"
        case .mg: return "milligrams"
        case .mcg: return "micrograms"
        case .kg: return "kilograms"
        case .oz: return "ounces"
        case .mL: return "milliliters"
        case .L: return "liters"
        case .flOz: return "fluid ounces"
        case .cup: return "cups"
        case .tablespoon: return "tablespoons"
        case .teaspoon: return "teaspoons"
        case .kcal: return "calories"
        case .iu: return "international units"
        default: return unit.symbol
        }
    }
}