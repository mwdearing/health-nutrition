# Today screen, quick water and Add intake

These screens live in the SwiftPM library target `NutritionUI` (package `ios/NutritionCore`). There is no app
project yet; the app target will wire `NutritionUI` later. Tests cover the view models only.

## Screens
- **Today** (`TodayView`, `TodayViewModel`): the water total, a quick-add water button, an undo button, one coverage
  line per tracked nutrient, and the intakes of the day.
- **Add intake** (`AddIntakeView`, `AddIntakeViewModel`): name, amount text, unit, category, time. No catalog or
  barcode lookup yet.

## Behaviour
- **Quick water** writes one intake through `JournalStore.create` (category `water`, component `water`, 250 mL by
  default, amount as `Decimal`). The store queues the outbox operations; this layer never delivers anything.
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
