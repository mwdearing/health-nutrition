import Foundation
import NutritionDomain

/// One sample the app target writes to HealthKit, described as plain data.
///
/// `NutritionJournal` may not import HealthKit, so the quantity type is named by its identifier
/// string and the app target turns this into an `HKQuantitySample` when it executes the plan. See
/// `docs/healthkit-writer.md` and [ADR 0002](docs/adr/0002-healthkit-sync.md).
public struct HealthKitSampleSpec: Sendable, Hashable {
    /// A HealthKit quantity type identifier string, such as `"HKQuantityTypeIdentifierDietaryWater"`.
    public let quantityTypeIdentifier: String
    /// The amount already converted into `unitSymbol`, as an exact decimal.
    public let amount: Decimal
    /// The HealthKit unit string for this sample: `"mL"`, `"g"`, `"mg"`, `"mcg"` or `"kcal"`.
    public let unitSymbol: String
    public let start: Date
    public let end: Date
    /// ADR 0002: one identifier per (intake, nutrient), so two nutrients never resolve against each other.
    public let syncIdentifier: String
    /// ADR 0002: the journal revision, so a higher version replaces the sample and a retry is harmless.
    public let syncVersion: Int

    public init(
        quantityTypeIdentifier: String,
        amount: Decimal,
        unitSymbol: String,
        start: Date,
        end: Date,
        syncIdentifier: String,
        syncVersion: Int
    ) {
        self.quantityTypeIdentifier = quantityTypeIdentifier
        self.amount = amount
        self.unitSymbol = unitSymbol
        self.start = start
        self.end = end
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
    }
}

/// The HealthKit type identifiers, as strings.
///
/// Each constant is named with a leading underscore so the identifier is legible right where it is
/// declared. A bare `HK…` name would read as a HealthKit type to anything scanning this module,
/// and nothing here is a HealthKit type: it is the string an `HKObjectType` is looked up by in the
/// app target.
private enum HealthKitTypeIdentifier {
    static let _HKQuantityTypeIdentifierDietaryWater = "HKQuantityTypeIdentifierDietaryWater"
    static let _HKQuantityTypeIdentifierDietaryEnergyConsumed = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
    static let _HKQuantityTypeIdentifierDietaryProtein = "HKQuantityTypeIdentifierDietaryProtein"
    static let _HKQuantityTypeIdentifierDietaryCarbohydrates = "HKQuantityTypeIdentifierDietaryCarbohydrates"
    static let _HKQuantityTypeIdentifierDietaryFatTotal = "HKQuantityTypeIdentifierDietaryFatTotal"
    static let _HKQuantityTypeIdentifierDietaryFiber = "HKQuantityTypeIdentifierDietaryFiber"
    static let _HKQuantityTypeIdentifierDietarySugar = "HKQuantityTypeIdentifierDietarySugar"
    static let _HKQuantityTypeIdentifierSodium = "HKQuantityTypeIdentifierSodium"
    static let _HKQuantityTypeIdentifierPotassium = "HKQuantityTypeIdentifierPotassium"
    static let _HKQuantityTypeIdentifierCalcium = "HKQuantityTypeIdentifierCalcium"
    static let _HKQuantityTypeIdentifierMagnesium = "HKQuantityTypeIdentifierMagnesium"
    static let _HKQuantityTypeIdentifierIron = "HKQuantityTypeIdentifierIron"
    static let _HKQuantityTypeIdentifierZinc = "HKQuantityTypeIdentifierZinc"
    static let _HKQuantityTypeIdentifierDietaryCaffeine = "HKQuantityTypeIdentifierDietaryCaffeine"
    static let _HKQuantityTypeIdentifierVitaminD = "HKQuantityTypeIdentifierVitaminD"
    static let _HKQuantityTypeIdentifierVitaminB12 = "HKQuantityTypeIdentifierVitaminB12"
    static let _HKQuantityTypeIdentifierDietaryFolate = "HKQuantityTypeIdentifierDietaryFolate"
}

/// One row of the nutrient mapping table: a journal nutrient key, the HealthKit type it lands in,
/// and the unit HealthKit wants it in.
public struct HealthKitNutrientMapping: Sendable {
    public let nutrientKey: String
    public let quantityTypeIdentifier: String
    public let unit: MeasureUnit

    public init(nutrientKey: String, quantityTypeIdentifier: String, unit: MeasureUnit) {
        self.nutrientKey = nutrientKey
        self.quantityTypeIdentifier = quantityTypeIdentifier
        self.unit = unit
    }
}

/// Builds the HealthKit write plan for one journal revision (NC-07). Nothing here touches
/// HealthKit: it is the pure decision of *what* would be written and under which sync metadata.
public enum HealthKitWritePlanner {
    /// Nutrient key to (identifier, unit), in nutrient-key order.
    ///
    /// The units are the ones HealthKit accepts for the dietary types; everything else is converted
    /// into them with `MeasureUnit` before a spec is built. Vitamin D, B12 and folate stay in
    /// micrograms because that is how HealthKit states them.
    public static let mappings: [HealthKitNutrientMapping] = [
        HealthKitNutrientMapping(nutrientKey: "water", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryWater, unit: .mL),
        HealthKitNutrientMapping(nutrientKey: "energy", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryEnergyConsumed, unit: .kcal),
        HealthKitNutrientMapping(nutrientKey: "protein", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryProtein, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "carbohydrate", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryCarbohydrates, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "fat", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryFatTotal, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "fiber", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryFiber, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "sugar", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietarySugar, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "sodium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierSodium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "potassium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierPotassium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "calcium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierCalcium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "magnesium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierMagnesium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "iron", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierIron, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "zinc", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierZinc, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "caffeine", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryCaffeine, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "vitaminD", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierVitaminD, unit: .mcg),
        HealthKitNutrientMapping(nutrientKey: "vitaminB12", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierVitaminB12, unit: .mcg),
        HealthKitNutrientMapping(nutrientKey: "folate", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryFolate, unit: .mcg),
    ]

    /// The plan for one revision: one spec per mapped nutrient whose total is `.known`.
    ///
    /// A total that is `.unknown`, `.notApplicable` or `.belowReportingThreshold`, a nutrient key
    /// with no mapping, an international-unit total and a total whose unit cannot be converted
    /// exactly are all skipped rather than written as zero. The `water` total is the millilitres of
    /// the intake's volume component, which the caller passes in like any other total.
    ///
    /// The specs come out sorted by nutrient key, so the same totals always plan the same order.
    /// `start` and `end` are both `occurredAt`: the sample is the intake itself, so a retry of the
    /// same revision rebuilds byte-identical metadata and cannot differ from `Date()`.
    public static func plan(
        intakeID: String,
        revision: Int,
        occurredAt: Date,
        totals: [String: NutrientValue]
    ) -> [HealthKitSampleSpec] {
        var specs: [HealthKitSampleSpec] = []
        for mapping in mappings.sorted(by: { $0.nutrientKey < $1.nutrientKey }) {
            guard let total = totals[mapping.nutrientKey], case .known(let amount, let unit) = total else {
                continue
            }
            guard let converted = try? Quantity(value: amount, unit: unit).converted(to: mapping.unit) else {
                continue
            }
            specs.append(
                HealthKitSampleSpec(
                    quantityTypeIdentifier: mapping.quantityTypeIdentifier,
                    amount: converted.value,
                    unitSymbol: mapping.unit.symbol,
                    start: occurredAt,
                    end: occurredAt,
                    syncIdentifier: syncIdentifier(intakeID: intakeID, nutrientKey: mapping.nutrientKey),
                    syncVersion: revision
                )
            )
        }
        return specs
    }

    /// The sync identifiers a delete has to remove, by identifier and this app's own source (ADR 0002).
    /// Sorted and deduplicated, so a delete is the same request however the caller collected its keys.
    ///
    /// Every key passed is listed, including a key this revision does not write: an earlier revision
    /// may have written it, and a nutrient that has since become unknown produces no sample to
    /// replace it, so it has to be deleted rather than left behind. The result is therefore a superset
    /// of what `plan` wrote for the same keys, and deciding which keys that is stays with the caller.
    public static func deletion(intakeID: String, keys: [String]) -> [String] {
        Array(Set(keys)).sorted().map { syncIdentifier(intakeID: intakeID, nutrientKey: $0) }
    }

    /// ADR 0002: one sync identifier per (intake, nutrient), `"<intakeID>.<nutrientKey>"`.
    public static func syncIdentifier(intakeID: String, nutrientKey: String) -> String {
        "\(intakeID).\(nutrientKey)"
    }
}