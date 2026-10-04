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
/// HealthKit names every dietary quantity type with the same `Dietary` prefix, the minerals and
/// vitamins included: `HKQuantityTypeIdentifierDietarySodium`, `HKQuantityTypeIdentifierDietaryIron`,
/// `HKQuantityTypeIdentifierDietaryVitaminD`. These are the identifiers Apple's
/// `HKQuantityTypeIdentifier` list defines.
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
    static let _HKQuantityTypeIdentifierDietarySodium = "HKQuantityTypeIdentifierDietarySodium"
    static let _HKQuantityTypeIdentifierDietaryPotassium = "HKQuantityTypeIdentifierDietaryPotassium"
    static let _HKQuantityTypeIdentifierDietaryCalcium = "HKQuantityTypeIdentifierDietaryCalcium"
    static let _HKQuantityTypeIdentifierDietaryMagnesium = "HKQuantityTypeIdentifierDietaryMagnesium"
    static let _HKQuantityTypeIdentifierDietaryIron = "HKQuantityTypeIdentifierDietaryIron"
    static let _HKQuantityTypeIdentifierDietaryZinc = "HKQuantityTypeIdentifierDietaryZinc"
    static let _HKQuantityTypeIdentifierDietaryCaffeine = "HKQuantityTypeIdentifierDietaryCaffeine"
    static let _HKQuantityTypeIdentifierDietaryVitaminD = "HKQuantityTypeIdentifierDietaryVitaminD"
    static let _HKQuantityTypeIdentifierDietaryVitaminB12 = "HKQuantityTypeIdentifierDietaryVitaminB12"
    static let _HKQuantityTypeIdentifierDietaryFolate = "HKQuantityTypeIdentifierDietaryFolate"
}

/// One row of the nutrient mapping table: the canonical journal nutrient key, the other keys the
/// journal is known to store that nutrient under, the HealthKit type it lands in, and the unit
/// HealthKit wants it in.
public struct HealthKitNutrientMapping: Sendable {
    /// The canonical key. It names the row in `plan`'s output order and in the sync identifier, so
    /// the same nutrient keeps the same sample whether the journal recorded it under its own key or
    /// under one of the aliases.
    public let nutrientKey: String
    /// Other keys that mean this same nutrient in stored totals. A barcode snapshot keeps the keys
    /// `LookedUpProduct.standardKeys` names (`energyKcal`, `carbohydrates`, `sugars`, …) verbatim,
    /// so the planner has to read them or the values they carry would never reach HealthKit.
    public let aliases: [String]
    public let quantityTypeIdentifier: String
    public let unit: MeasureUnit

    /// The canonical key first, then the aliases, which is the order a total is resolved in.
    public var acceptedKeys: [String] { [nutrientKey] + aliases }

    public init(nutrientKey: String, aliases: [String] = [], quantityTypeIdentifier: String, unit: MeasureUnit) {
        self.nutrientKey = nutrientKey
        self.aliases = aliases
        self.quantityTypeIdentifier = quantityTypeIdentifier
        self.unit = unit
    }
}

/// Builds the HealthKit write plan for one journal revision (NC-07). Nothing here touches
/// HealthKit: it is the pure decision of *what* would be written and under which sync metadata.
public enum HealthKitWritePlanner {
    /// Nutrient key to (aliases, identifier, unit).
    ///
    /// Every identifier is one of HealthKit's dietary quantity types, prefix included. The units are
    /// the ones HealthKit accepts for them; everything else is converted into them with
    /// `MeasureUnit` before a spec is built. Vitamin D, B12 and folate stay in micrograms because
    /// that is how HealthKit states them. An alias is another key the journal is known to store that
    /// same nutrient under; it resolves to this row, never to a second one.
    public static let mappings: [HealthKitNutrientMapping] = [
        HealthKitNutrientMapping(nutrientKey: "water", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryWater, unit: .mL),
        HealthKitNutrientMapping(nutrientKey: "energy", aliases: ["energyKcal"], quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryEnergyConsumed, unit: .kcal),
        HealthKitNutrientMapping(nutrientKey: "protein", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryProtein, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "carbohydrate", aliases: ["carbohydrates"], quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryCarbohydrates, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "fat", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryFatTotal, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "fiber", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryFiber, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "sugar", aliases: ["sugars"], quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietarySugar, unit: .g),
        HealthKitNutrientMapping(nutrientKey: "sodium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietarySodium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "potassium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryPotassium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "calcium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryCalcium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "magnesium", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryMagnesium, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "iron", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryIron, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "zinc", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryZinc, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "caffeine", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryCaffeine, unit: .mg),
        HealthKitNutrientMapping(nutrientKey: "vitaminD", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryVitaminD, unit: .mcg),
        HealthKitNutrientMapping(nutrientKey: "vitaminB12", quantityTypeIdentifier: HealthKitTypeIdentifier._HKQuantityTypeIdentifierDietaryVitaminB12, unit: .mcg),
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
            guard let amount = resolvedAmount(for: mapping, in: totals) else {
                continue
            }
            specs.append(
                HealthKitSampleSpec(
                    quantityTypeIdentifier: mapping.quantityTypeIdentifier,
                    amount: amount,
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

    /// The amount one row plans, converted into its HealthKit unit, or nil when there is nothing to
    /// write. The keys are read in order — the canonical key first, then the aliases — and the first
    /// one that is `.known` and converts exactly wins, so a canonical key and the alias for the same nutrient can never
    /// produce two samples, and an alias can stand in for a canonical key that is not known.
    private static func resolvedAmount(for mapping: HealthKitNutrientMapping, in totals: [String: NutrientValue]) -> Decimal? {
        for key in mapping.acceptedKeys {
            guard let total = totals[key], case .known(let amount, let unit) = total else {
                continue
            }
            if let converted = try? Quantity(value: amount, unit: unit).converted(to: mapping.unit) {
                return converted.value
            }
        }
        return nil
    }

    /// The sync identifiers a delete has to remove, by identifier and this app's own source (ADR 0002).
    /// Sorted and deduplicated, so a delete is the same request however the caller collected its keys.
    ///
    /// Every key passed is listed, including a key this revision does not write: an earlier revision
    /// may have written it, and a nutrient that has since become unknown produces no sample to
    /// replace it, so it has to be deleted rather than left behind. The result is therefore a superset
    /// of what `plan` wrote for the same keys, and deciding which keys that is stays with the caller.
    ///
    /// An alias is resolved to its canonical key first, so a caller that names a nutrient the way a
    /// barcode snapshot stored it deletes the sample that was actually written.
    public static func deletion(intakeID: String, keys: [String]) -> [String] {
        Array(Set(keys.map { canonicalKey(for: $0) })).sorted().map { syncIdentifier(intakeID: intakeID, nutrientKey: $0) }
    }

    /// The canonical key for a nutrient, whether it was given as the canonical key or as one of its
    /// aliases. A key no row maps is returned unchanged, so an unmapped key never loses its identity.
    public static func canonicalKey(for key: String) -> String {
        mappings.first { $0.acceptedKeys.contains(key) }?.nutrientKey ?? key
    }

    /// ADR 0002: one sync identifier per (intake, nutrient), `"intake:<intakeID>:<nutrientKey>"`. The
    /// `intake:<id>:<key>` shape is the one the HealthRelay intake-context v1 receiver contract and its
    /// golden vectors use, so the writer and the receiver name the same samples.
    public static func syncIdentifier(intakeID: String, nutrientKey: String) -> String {
        "intake:\(intakeID):\(nutrientKey)"
    }
}