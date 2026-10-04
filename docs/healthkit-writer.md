# HealthKit writer: the write plan

## What it is
The pure half of the HealthKit writer (NC-07). `HealthKitWritePlanner` in
`ios/NutritionCore/Sources/NutritionJournal/HealthKitWritePlan.swift` answers one question: given a
journal revision and its nutrient totals, which HealthKit samples would be written, and with which
sync metadata? It answers it as plain data. `NutritionJournal` may not import HealthKit —
`scripts/lint_swift_sources.py` forbids `import HealthKit` in that layer, and the rule exists so the
journal stays testable on macOS — so the quantity type is named by its identifier **string**
(`"HKQuantityTypeIdentifierDietaryWater"`) and the app target looks the type up and builds the
`HKQuantitySample` later. Nothing in this module authorizes, saves, queries or deletes anything.

The behaviour follows [ADR 0002](../adr/0002-healthkit-sync.md), which records what HealthKit actually
did on a device rather than what its documentation says. The three consequences that shape this
plan:

- **One sync identifier per (intake, nutrient)**, `"<intakeID>.<nutrientKey>"`. A shared identifier
  would let two nutrients of one intake resolve against each other; the spike in ADR 0002 gave water
  and protein separate identifiers for exactly this reason.
- **The sync version is the journal revision.** A higher version replaces the sample; an equal
  version replaces it again (harmless, because the sample is rebuilt entirely from the stored
  revision); a lower version is silently ignored and still reports success, so the writer never
  treats a successful save as proof that the store now holds this revision.
- **Timestamps come from the intake.** `start` and `end` are both `occurredAt`, the intake's own
  time. Nothing here reads `Date()`: a retry has to rebuild identical metadata, or an equal-version
  replacement would write a different sample than the one it replaces.

## The mapping table
`HealthKitWritePlanner.mappings` is the whole table. The units are the ones HealthKit accepts for
these types, and every total is converted into them with `MeasureUnit` before a spec is built, so
the planner never does arithmetic of its own: `Decimal` throughout, exact powers of ten only.

| Nutrient key | HealthKit identifier | HealthKit unit |
|---|---|---|
| `water` | `HKQuantityTypeIdentifierDietaryWater` | `mL` |
| `energy` | `HKQuantityTypeIdentifierDietaryEnergyConsumed` | `kcal` |
| `protein` | `HKQuantityTypeIdentifierDietaryProtein` | `g` |
| `carbohydrate` | `HKQuantityTypeIdentifierDietaryCarbohydrates` | `g` |
| `fat` | `HKQuantityTypeIdentifierDietaryFatTotal` | `g` |
| `fiber` | `HKQuantityTypeIdentifierDietaryFiber` | `g` |
| `sugar` | `HKQuantityTypeIdentifierDietarySugar` | `g` |
| `sodium` | `HKQuantityTypeIdentifierSodium` | `mg` |
| `potassium` | `HKQuantityTypeIdentifierPotassium` | `mg` |
| `calcium` | `HKQuantityTypeIdentifierCalcium` | `mg` |
| `magnesium` | `HKQuantityTypeIdentifierMagnesium` | `mg` |
| `iron` | `HKQuantityTypeIdentifierIron` | `mg` |
| `zinc` | `HKQuantityTypeIdentifierZinc` | `mg` |
| `caffeine` | `HKQuantityTypeIdentifierDietaryCaffeine` | `mg` |
| `vitaminD` | `HKQuantityTypeIdentifierVitaminD` | `mcg` |
| `vitaminB12` | `HKQuantityTypeIdentifierVitaminB12` | `mcg` |
| `folate` | `HKQuantityTypeIdentifierDietaryFolate` | `mcg` |

Conversion is exact: 1500 mg of protein plans as 1.5 g, 1500 mcg of sodium as 1.5 mg, 1 mg of
vitamin D as 1000 mcg, 0.25 L of water as 250 mL. Kilojoules are not a `MeasureUnit` in this
project, so an energy total has to reach the planner already in `kcal`; the planner has no
kilojoule factor to apply and would skip a total it cannot convert.

## What the plan does not write
A total that is `.unknown`, `.notApplicable` or `.belowReportingThreshold` is skipped, and so is:

- a nutrient key with no mapping in the table,
- an international-unit total (IU never converts, and HealthKit has no IU dietary unit),
- a total whose unit cannot be converted to the mapped unit, such as energy in grams.

Skipping means *no sample at all*, never a sample of zero: the journal reads an absent nutrient as
unknown, and writing 0 would turn "not stated" into "none" in the Health app. A nutrient that is
genuinely `.known(0)` is a label statement and is written as zero.

Water is not special-cased: the `water` total is the millilitres of the intake's volume component,
which the caller passes in like any other total.

## Determinism
`plan(intakeID:revision:occurredAt:totals:)` returns the specs sorted by nutrient key, so the same
totals always plan the same order no matter how the totals dictionary was built.

## Deletion
`deletion(intakeID:keys:)` returns the sync identifiers to remove, sorted and deduplicated. Per ADR
0002 the journal keys nothing off a HealthKit UUID — UUIDs change on every accepted save — and a
delete goes by sync identifier **and** this app's own source, so a sample another app wrote is never
touched. `HealthKitSampleSpec` deliberately carries no UUID field for the same reason.

**A delete covers every key the caller passes, not only the ones this revision writes.** A later
revision can drop a nutrient: the plan then produces no sample for it (an unknown total is skipped,
never written as zero), so nothing would replace the sample an earlier revision wrote and Health would
keep showing a stale value. Deleting the stale sample and then writing the current revision is the
only way to retract it, which is why the identifiers are a superset of the ones `plan` returns for the
same keys. Which keys a delete covers is the caller's decision — the journal knows what a revision
recorded — so the planner lists every key it is given.

## Tests
`ios/NutritionCore/Tests/NutritionJournalTests/HealthKitWritePlanTests.swift` covers the identifier
and version shape, every skip case, the exact conversions, water, the deterministic order, the
timestamps and the deletion identifiers. `swift test` runs on macOS in CI; the values are synthetic.