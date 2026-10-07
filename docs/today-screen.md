# Today screen, quick water and Add intake

These screens live in the SwiftPM library target `NutritionUI` (package `ios/NutritionCore`). There is no app
project yet; the app target will wire `NutritionUI` later. Tests cover the view models only.

## Screens
- **Today** (`TodayView`, `TodayViewModel`): the water total, a quick-add water button, an undo button, one coverage
  line per tracked nutrient, and the intakes of the day.
- **Add intake** (`AddIntakeView`, `AddIntakeViewModel`): name, amount text, unit, category, time. No catalog or
  barcode lookup yet.

## Behaviour
- **Quick water** writes one intake through `JournalStore.create` (category `water`, component `water`, the
  configured amount in mL, amount as `Decimal`). The store queues the outbox operations; this layer never
  delivers anything. The amount is configurable: see [Units and the quick-water amount](#units-and-the-quick-water-amount).
- **Undo** is available for 10 seconds, measured with a clock value passed in by the caller. It calls
  `JournalStore.delete(intakeID:now:)`, so history is kept and delete operations are queued. After 10 seconds it is
  gone.
- **Amount text** is parsed with a fixed POSIX parser: digits and at most one point, greater than zero, no locale, no
  binary floating point. Invalid text sets a field error and writes nothing.
- **Local day**: an intake is on Today when its time falls on the same calendar day as "now" in the intake's own time
  zone. Deleted intakes are hidden.
- **Water total** is the exact `Decimal` sum, in mL, of the volume components of intakes with category `water`. Other
  categories never contribute, whatever their unit. A component whose unit is not a volume is skipped and counted
  (`waterSkippedCount`), never treated as zero. So is a stored amount that is NaN or not above zero, checked before and
  after conversion to mL.
- **Invalid time zone**: a stored intake whose time zone identifier is not a valid time zone is left out of Today (no
  row, not in the water total or coverage) and counted in `skippedIntakeCount`, which is reset on each load. There is no
  fallback to the current time zone for stored intakes.

## Units and the quick-water amount

Two display preferences live in `ios/NutritionCore/Sources/NutritionUI/DisplayPreferences.swift`:
`UnitSystem` (metric or US customary) and the quick-water amount in mL. The defaults are metric and
250 mL. `UserDefaultsDisplayPreferences` persists them under namespaced `display.` keys, written
synchronously; `InMemoryDisplayPreferences` is the in-memory implementation for tests. The app builds
one `UserDefaultsDisplayPreferences` in `AppServices` and passes it to every screen, so a change made
on one screen is read by the next.

Where they are set: the **Units** section on the Connections and privacy screen
(`ConnectionsPrivacyView`), reachable from the Library tab's Connections section. It offers a
unit-system picker and a quick-water amount field. The amount is validated with the same POSIX parser
as Add intake and must be above zero; anything else is refused with a message and the stored value is
left alone.

What the preference changes, and what it does not:

- **Offered**: the Add-intake `Picker("Unit")` lists the registry's whole set for metric, and `oz` and
  `fl oz` first for US customary. Both are always available.
- **Input**: `AddIntakeViewModel.save` converts an amount entered in `oz` or `fl oz` to the metric unit
  it stands for before storing it, by the exact factor (× 28.349523125 or × 29.5735295625, exact in a
  `Decimal`), and stores the metric unit. So one ounce entered is stored as 28.349523125 g. The ounces
  are input and display units only.
- **Displayed**: metric shows the stored unit unchanged, so 10 mg reads `10 mg` and is never scaled
  into grams. US customary converts only base-scale mass and volume (`g`/`kg`→`oz`, `mL`/`L`→`fl oz`)
  on the Today lines, the water total, both quick-water button strings and the entry detail amounts.
  `mg`, `mcg`, energy, counts and international units are shown as stored. A converted amount carries
  one fraction digit at or above ten, two above one, and up to four below one, so 0.5 g reads
  `0.0176 oz` and 500 g reads `17.6 oz`. An amount too small for the unit's digits reads
  `< 0.0001 oz` rather than zero. The entry detail line is recomputed from the draft in the text field
  and is hidden for an amount stored as unknown.
- **Not stored, not exported, not delivered**: because `oz` and `fl oz` never reach storage, the journal
  export, the digests, HealthKit delivery and the relay encoder are metric whatever the unit system.
  The quick-add button writes the configured amount in mL whatever the unit system, so an export of a
  US-customary journal is byte-identical to a metric one. The recipe editor is metric for the same
  reason and offers neither ounce: a recipe yield becomes the component of a logged entry through
  `RecipeLogger.portionQuantity`, which has no normalisation step of its own, so an ounce yield would
  be stored as an ounce.
- **Erased with everything else**: the unit system and the quick-water amount are stored values, so
  **Erase all data** removes both `display.` keys rather than overwriting them with the defaults. See
  [erase-all-data.md](erase-all-data.md).

The spoken strings are built from the same figures as the visible ones, through
`DisplayAmount.spokenAmount`, so an amount too small for the unit is read as "less than 0.0001" rather
than announced as a zero that is not there.

The button text and its accessibility label both come from `TodayViewModel.quickWaterLabel` and
`quickWaterAccessibilityLabel`, so they cannot drift from the amount the button writes.

## Coverage wording
Each tracked nutrient (potassium, sodium, protein, fiber by default) shows `"<missing> of <total> foods lack <nutrient>"`,
for example "2 of 5 foods lack potassium".

## Unknown is not zero
Values come from an injected `NutrientFactsLookup`. The default, `UnknownNutrientFacts`, always answers `.unknown`
because there is no catalog yet. An unknown value counts as missing. A known zero is known, so it is not missing.
Not-applicable values are left out of both numbers. Below-reporting-threshold values count in the total but are not
missing.

The app injects `SnapshotNutrientFacts`, which answers from the nutrient values the entry's product snapshot carries.
A snapshot is read at most once per load however many components and nutrients refer to it, and one that cannot be read
is treated as absent, which reads as unknown rather than as zero. The values are the product's own, on the basis its
snapshot names: coverage asks only whether a value is known, and the stored value is never scaled to the component's
amount. An entry typed by hand has no snapshot, so it stays unknown until a product or a calculated recipe is attached.

## Boundaries
`NutritionUI` imports no HealthKit and no networking. Colours come only from the design tokens through
`TokenColors.swift`; text uses Dynamic Type styles; every button and image has an accessibility label.
