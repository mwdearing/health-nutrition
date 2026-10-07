import Foundation
import NutritionDomain
import NutritionJournal

/// Which units the Add-intake picker offers, and in what order.
///
/// This is about what a person is OFFERED. What they choose is stored as entered, in the unit they
/// chose, so changing this list never rewrites anything already logged.
public enum UnitSelection {
    /// Every unit the picker offers under `system`, the system's own units first.
    public static func offered(for system: UnitSystem) -> [MeasureUnit] {
        let preferred = preferred(for: system)
        let rest = UnitRegistry.all.filter { unit in !preferred.contains(unit) }
        return preferred + rest
    }

    /// The units a system puts first, which is the whole list for metric and the two ounces for US.
    public static func preferred(for system: UnitSystem) -> [MeasureUnit] {
        switch system {
        case .metric: return UnitRegistry.all
        case .usCustomary: return [.oz, .flOz]
        }
    }
}

/// A stored amount shown in the unit the reader chose. Never written back: a stored value keeps the
/// unit it was entered in.
public struct DisplayAmount: Equatable {
    public let amount: Decimal
    public let unit: MeasureUnit

    public init(amount: Decimal, unit: MeasureUnit) {
        self.amount = amount
        self.unit = unit
    }

    /// The amount and its symbol, as one line of text.
    public var text: String {
        "\(DecimalFormatting.text(amount)) \(unit.symbol)"
    }
}

/// How a stored amount is shown under a unit system.
///
/// Only mass and volume are converted. Energy, counts and international units have no customary
/// counterpart here, so they are shown exactly as they were stored.
public enum AmountDisplay {
    /// Fraction digits a converted amount carries. A converted ounce is a kitchen measure, and a
    /// hundredth of one says nothing the reader can act on, so the value is rounded for showing.
    public static let convertedFractionDigits = 1

    /// The mass unit a system shows weights in.
    public static func massUnit(for system: UnitSystem) -> MeasureUnit {
        system == .usCustomary ? .oz : .g
    }

    /// The volume unit a system shows volumes in.
    public static func volumeUnit(for system: UnitSystem) -> MeasureUnit {
        system == .usCustomary ? .flOz : .mL
    }

    /// The unit a stored unit is shown in, or the stored unit itself when the dimension has no
    /// customary counterpart.
    public static func displayUnit(for stored: MeasureUnit, system: UnitSystem) -> MeasureUnit {
        switch stored.dimension {
        case .mass: return massUnit(for: system)
        case .volume: return volumeUnit(for: system)
        default: return stored
        }
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
        return DisplayAmount(
            amount: DisplayRounding.rounded(converted.value, fractionDigits: convertedFractionDigits),
            unit: target)
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
        case .mL: return "millilitres"
        case .L: return "litres"
        case .flOz: return "fluid ounces"
        case .kcal: return "calories"
        case .iu: return "international units"
        default: return unit.symbol
        }
    }
}