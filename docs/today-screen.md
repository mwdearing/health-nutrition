# Today screen, quick water, totals and daily goals

These screens live in the SwiftPM library target `NutritionUI` (package `ios/NutritionCore`), and the stores they
read live in `NutritionJournal`. The app target wires them together. Tests cover the view models only.

## Screens
- **Today** (`TodayView`, `TodayViewModel`): the date, a **Daily goals** card with one goal bar per tracked
  nutrient (see "Goal bars" below) and an "Edit goals" link, a **Water** card with the total, the quick-add water
  capsule and its undo, then the day's food and drink entries grouped by meal (Breakfast, Lunch, Dinner, Snack, then
  Other), and one footer line when entries state no nutrition values. Each entry row opens that entry in the entry
  screen, so a row logged late on the wrong day is corrected where it is noticed. Add is the "Add food or drink"
  capsule the app shell holds above the tab bar on every tab; Today has no Journal or Library link and no toolbar
  plus. Settings (and through it the daily goals and the privacy screen) is the gear on every tab.
- **Add intake** (`AddIntakeView`, `AddIntakeViewModel`): name, amount text, unit, category, meal, time.
- **Daily goals** (`GoalsView`, `GoalsViewModel`): the target for each offered nutrient, and the way to change or
  clear it. Reached from Today's "Edit goals" link or from Settings; the Library no longer holds a Connections section.
  Dismissing Settings reloads Today and Journal, so changed goals immediately update both screens.

## First day
**The welcome** is a full screen shown once per install, on the first launch of the app (`RootView` presents
`WelcomeView` in a full-screen cover while the welcome flag is not set). It shows the title "HealthNutrition", the
sentence "Log what you eat and drink. See it against goals you set.", and three cards: "Scan a label or barcode, or
type it in", "Your journal stays on this phone", and "No scores, no advice". It has two actions:
- **Get started** stores the welcome flag and closes the screen.
- **Restore from an export** stores the flag, closes the screen and opens Settings. The restore itself is the
  "Restore from an export" button under **Privacy** in Settings, which works only while the journal is empty.

The welcome asks for no permission, makes no network request and stores nothing but the flag. It is not shown while
the design-system screenshots are captured. **Settings > About** has **Show welcome again**, which shows the welcome
once more; it changes no other setting. Erase all data clears the flag, so the welcome shows again on the next
launch (not at once).

**The checklist card** is titled "Getting started". It sits on Today above **Daily goals** while it is shown, and has
four rows in this order:
1. **Log your first food or drink**: done when the journal holds at least one entry, on any day. Tapping it opens
   Add.
2. **Set a daily goal**: done when at least one daily goal is stored. Tapping it opens the daily goals.
3. **Choose units**: shows the current system under the title, "Metric" or "US". Tapping it marks the step done at
   once, then opens the units settings. The mark is stored, so it stays done even if the units are not changed.
4. **Connect Apple Health**: a placeholder with a Later badge. It is disabled, announced as "Not available yet", and
   never done in this build.

Steps are read again when the app starts, when it returns to the foreground, when Settings closes, after an entry is
added or edited, after an erase, and after the units step. The card disappears once the first three steps are all
done, and it returns only if one of them becomes undone again (for example, every entry is deleted). **Hide**
removes the card at once and stores the choice, so it stays hidden on later launches until an erase clears it. The
fourth step never ticks off, so it never keeps the card on screen.

## Totals
A **DailyTotals** (`ios/NutritionCore/Sources/NutritionUI/DailyTotals.swift`) is what one day adds up to, one entry
per nutrient. It is summed by `DailyTotalsBuilder.totals(for:store:lookup:nutrients:)` from the current revision of
every intake the caller hands it, so a corrected entry contributes only its corrected amounts and a deleted one
contributes nothing.

Where an amount comes from is decided by two rules, because those are the two the data has:

- A component that **measures the nutrient itself** is summed directly. Water is the case this reaches: an entry in
  category `water` states its volume in its own unit, so it is already the amount. Litres and millilitres are added,
  exactly.
- A **product snapshot** states its nutrients for the amount its `labelBasis` names, so those values are scaled by the
  factor `IntakeContextSnapshotBasis.scalingFactor(labelBasis:logged:)` gives — the same factor the intake-context
  encoder uses — and summed exactly. 40 g of a product stating 13 g of protein per 100 g contributes 5.2 g. An entry
  with no snapshot asks the injected `NutrientFactsLookup` about each component, so a food the catalog can still answer
  still contributes.

**Supplements never join either coverage count.** Their declared snapshot nutrients still contribute
to totals, scaled by the logged amount. Nutrients a supplement does not declare supply no contribution
and do not make otherwise known food totals unknown; an unknown food value still makes the total unknown.

**The kind picker remains the user's choice.** A barcode reply cannot replace a Food, Drink or
Supplement selection made before or during the lookup. A source-derived kind may be replaced by the
next source only while the user has not explicitly selected a kind.

A **per-serving basis that also states its serving as a quantity** — "per serving (30 g)" or "per serving (240
mL)", which is what a barcode lookup or a label panel writes when it knows how big a serving is — is scaled from
that stated serving and the amount logged, because the entry records the food as an amount and a count cannot be scaled
from a log that states none. 30 g of a 30 g serving is one serving and 60 g is two; 480 mL of a 240 mL serving is two.
The requirement is that **the two agree in dimension**, not that they are masses: a panel that states a serving in
millilitres and an entry logged in millilitres say the same thing about how much was eaten, so it scales too. The
logged amount is converted into the stated serving's unit first, so 0.48 L counts as the 480 mL it is. A mass serving
against a logged volume does not agree and is nil, as is a serving stated no quantity at all — "per serving",
"per serving (1 large biscuit)", "per serving (a handful)" — so the nutrient stays unknown rather than being scaled by
a guess. A household measure that carries its gram weight in its own brackets, "per serving (1 bar
(30 g))", is read from the innermost brackets, so the 30 g is what scales. That is done by the totals builder and not by the basis type itself: the intake-context encoder answers the
same basis as unresolvable and its contract with the relay receiver says so, so changing what the basis means would be
a contract change rather than one reader being able to answer a question the data can answer.

The key a value is read under is resolved through the **canonical nutrient mapping** `HealthKitWritePlanner` holds,
not by an exact dictionary lookup. A barcode snapshot keeps the keys `LookedUpProduct.standardKeys` names —
`energyKcal`, `carbohydrates`, `sugars` — while a goal and Today ask for `energy`, `carbohydrate` and `sugar`, so
the canonical key is read first and its aliases after it, and the first one that says anything at all is what the entry
carries. Reading the asked key alone made the day's energy unknown where the snapshot states 400 kcal; reading the alias
first would count a snapshot stating both keys twice.

**Water is the one nutrient only one kind of entry speaks to**, and neither kind speaks to the other's: a drink states
nothing but its own volume, and a food states no water unless the product itself states water. A food therefore
contributes nothing to the water line, which is what keeps a day holding one food from reporting its water as unknown
rather than as what was drunk.

Summing runs through `NutritionDomain.NutrientTotal.sum`, which adds the known values exactly and reports the
unknowns in a `Coverage`. Three cases are answered as unknown rather than as a number, because "0 g of protein" and
"protein was never known" are different facts and only one of them is true, and because a smaller number presented as
the day's true total under-reports it:

- a snapshot whose basis the journal cannot resolve — `per 100 g or mL`, `per 100 kcal` — states its value for
  some other amount than the one logged, so the nutrient is unknown;
- two known values in different dimensions, which cannot be added, so the nutrient is unknown rather than one of them
  being dropped and the smaller sum reported as the day's true total;
- **coverage that is uncertain**: one entry stating its nutrient below the reporting threshold carries a bound rather
  than an amount, so adding it to what the other entries stated cannot produce the day's total, only a number smaller
  than the truth by an unknown amount. It is answered as unknown rather than printed as a lower bound, because a line
  reading "at least 5 g of 60 g" compares a bound against a target as though it were the day's figure, and a person
  cannot tell from it whether the day is met. Unknown is the one answer that cannot be mistaken for the day being short.

A day with nothing logged is unknown for every nutrient, for the same reason.

### One day at a time
The day is the caller's to decide and `DailyTotalsBuilder` never sees two at once. `TodayViewModel` keeps the
intakes on the same local day as now; `JournalViewModel` groups by day. Both use **each intake's own stored time
zone**, as `JournalViewModel` already did for its rows, so one instant logged in two zones is two local days and
neither day absorbs the other's entries. An intake whose stored time zone is not a valid time zone is left out with
no fallback, exactly as it already was.

`JournalDaySection` carries that day's `DailyTotals`, and `JournalViewModel.totalsText(totals:tracked:goals:)`
renders it as one compact line per day with the nutrients that have a target first. A nutrient the day cannot answer
for is left off that line rather than written as "unknown", because the entries below it say which could not be
read; a day where nothing at all is known says so on its own.

## Daily goals
A **NutrientGoal** (`ios/NutritionCore/Sources/NutritionJournal/GoalStore.swift`) is a nutrient key, an exact
`Decimal` target and a `MeasureUnit`. Goals are data rather than settings: they are stored, not `UserDefaults` or
`@AppStorage`, and "Erase all data" clears them with everything else.

`GoalsViewModel.sections` presents **Energy and macros** (Energy, Protein, Carbohydrate, Fat, Fiber),
**Water**, **Minerals** (Sodium, Potassium), and **From your labels**. Label compounds retain their printed
names and show "Added by a scanned label". Each row has an inline target field and a unit menu restricted
to its nutrient's dimension. `commitTarget(for:)` saves on submit or focus loss; a blank field removes
the goal and displays "None". Invalid numbers show "Enter a number above zero." beneath the field,
without changing the saved goal. Store failures remain notices.

Water targets use the shared display preferences: fl oz under US and whole mL under metric.
The water unit menu offers volumes only. Input is converted through `Quantity` and stored as an
exact `Decimal` in mL; an existing goal is converted back for the field and target text.
An unchanged water draft in the same display unit is not written back on submit or focus loss:
2,000 mL shown as 67.6 fl oz remains exactly 2,000 mL until the field is edited.
The Today water card and Journal water totals use `AmountDisplay.water`: a 12 fl oz intake against
a 64 fl oz goal reads `12 fl oz of 64 fl oz`, or `355 mL of 1,893 mL` under metric.
Bar fractions and goal comparisons still use the exact stored amounts, not the rounded display.
Positive water amounts rounded to zero are shown as a bound, `< 1 mL` or `< 0.0001 fl oz`.
The US bound uses `AmountDisplay.smallestShown`, matching quick-water strings.
The same bound is spoken for accessibility; an actual zero still displays as zero.
Settings' quick-water equivalence and entry detail's converted line use `AmountDisplay` as well.

Entry rows choose their decorative SF Symbol from the intake category and product kind:
water uses `drop.fill`, drinks `cup.and.saucer.fill`, supplements `pills.fill`, and food `fork.knife`.
Today and Journal carry the water category separately from product kind; water takes precedence.
Icons are hidden from accessibility, and the row's accessibility text includes its kind word.

**Clear all goals** asks for confirmation before `clearAllGoals()` removes every stored target,
including compound goals. Targets use primary text colour, with no rating implied by colour.
The footer states: "A goal is a number you set. The app compares your day against it and gives no advice or rating."
Each **Show on Today** switch is disabled, with a Later badge and accessibility value "Not available yet";
it does not change the tracked list.

`GoalStore` is the protocol; `SwiftDataGoalStore` persists it in its own `goals.store`, opened in `AppServices.make`
next to the journal, favorites and recipe files and listed in the `erasers:` array; `InMemoryGoalStore` is the
in-memory implementation tests use, which can also be told to refuse a write or fail a read. There is **one goal per
nutrient key**: a second write replaces the first rather than leaving two targets to choose between. A target of
zero, a negative one or a NaN is refused, because each would make a day read as met before anything was logged. A
target in the **wrong dimension** is refused too: `NutrientGoal.validate()` requires the unit to share the dimension
the nutrient's total is read in, which comes from the canonical nutrient mapping — so `UnitError.dimensionMismatch`
for "2 g" of energy or "2000 kcal" of water, and a screen that stored them would compare a kcal total against a gram
target it can neither show as met nor as missed. A nutrient no row maps has no dimension to check against, so only its
amount is checked.

`TodayViewModel` takes the goal store as an optional `goals:` argument, and a read that throws is **reported** in
`errorMessage` rather than swallowed into an empty goal list: a store that cannot be read is not a person who has set
no targets, and showing every nutrient as "no goal set" would be a claim about the person rather than about the store.
The day itself is still knowable without the targets, so the totals remain as plain totals.

A stored row that cannot be decoded — an unparseable decimal, a target that is not above zero, or a unit symbol this
registry does not hold — **fails the whole read**, `goals()` and `goal(for:)` alike. Leaving it out returned a
shorter list that looked complete, so a corrupt row read as "no goal set for this nutrient" rather than as a store
that needs attention, and a caller had no way to tell the two apart. Repairing the row, or an erase, makes the store
read again: the failure was the row, not the store.

**Tracked nutrients** are the existing `defaultTrackedNutrients` in their own fixed order, whether or not those
nutrients have goals, followed by the goals' keys that are outside it, alphabetically — the constant is a fallback
for the nutrients without a target, not the only way a nutrient is tracked. So a goal for a nutrient outside the
defaults is shown, and a fallback nutrient nobody set a target for is still tracked. The order is stated in one place
and is not the store's: `GoalStore.goals()` sorts by nutrient key while the fallback has an order of its own, so asking
which of the two leads made the list depend on how the store happened to return the goals. Coverage is built from this
same list, so a nutrient with a target is also one the screen says how much of the day is known about.

Each tracked nutrient gets one `NutrientProgressLine`, and the line is plain text because that is what a test asserts
and what the screen shows:

| the day | a goal exists | the line reads |
|---|---|---|
| 52 g of protein | 60 g | `Protein 52 g of 60 g` |
| 52 g of protein | none | `Protein 52 g` |
| unknown | 60 g | `Protein unknown` |

A day above its target still shows the real figure rather than capping at the target. A target in a different metric
unit is shown as the person set it rather than silently converted, so the comparison on screen is the one that was
entered.

The Goals screen offers a fixed list of nutrients (`NutrientGoalChoices.keys`) rather than whatever the catalog
holds, so a target is always one a person can correct. In addition to that list it offers every compound key the
journal's current snapshots carry — a captured supplement panel stores `creatine-monohydrate`, and the screen adds
it once an entry holds it, so a creatine goal can be set and the day's creatine total appears on Today. Each is
offered **only in its own dimension**, from the same
canonical mapping: water in volumes, energy in kilocalories, and the rest in masses. Energy in grams was a category
error rather than a rounding one — it was offered, accepted and stored, and the line then compared a kcal total
against a gram target. No count or international unit is offered either, so a target cannot be set in a unit its
totals are never counted in.

The two ounces are excluded as well, by the same rule the recipe editor applies
(`RecipeEditorViewModel.unitSymbols`). `oz` and `fl oz` are input and display units that Add intake normalises to
grams and millilitres on the way in; a target has no such step, because the progress line shows the day's total in
its own unit beside the target as it was set rather than converting one to the other. An ounce target would therefore
read "Protein 52 g of 2 oz" — two numbers not in the same unit. `UnitRegistry` grew the ounces for display, and what
a nutrient is offered is the units its total is stored in, not the units a person may type.

Text that is not a positive number is refused rather than rounded or guessed at.

## Behaviour
- **Quick water** writes one intake through `JournalStore.create` (category `water`, component `water`, the
  configured amount in mL, amount as `Decimal`). The store queues the outbox operations; this layer never
  delivers anything. The amount is configurable: see [Units and the quick-water amount](#units-and-the-quick-water-amount).
- **Entry rows** carry the entry's meal as a secondary line when it states one, and read out as the name, amounts,
  time in the entry's stored zone, and then the meal. They open the entry through an `onSelect` closure; a host that
  passes none leaves the rows as plain text.
- **Meal** is picked next to **When** on the Add form: `None` plus the four labels of `MealLabel`. `None` is a real
  answer and the form starts on it — no label is inferred from the hour, because the label is the person's own
  answer and a guessed one puts a word in their record that they never gave. The choice is stored as the label's raw
  value in `Intake.meal`, so a repeat and a favourite keep copying it.
- **Undo** is available for 10 seconds, measured with a clock value passed in by the caller. It calls
  `JournalStore.delete(intakeID:now:)`, so history is kept and delete operations are queued. After 10 seconds it is
  gone.
- **Amount text** is parsed with a fixed POSIX parser: digits and at most one point, greater than zero, no locale, no
  binary floating point. Invalid text sets a field error and writes nothing.
- **Typed amounts** on the Add form, the goal targets, the quick-water amount, the recipe editor and a recipe's
  portion, the entry screen and label corrections are read through `AmountParser.parseTyped`: where the device's region uses a comma as its decimal separator, one comma is read
  as that separator ("2,5" is two and a half); elsewhere a comma is refused as before. A point is accepted in
  every region, and mixed or repeated separators are refused. Stored and exported text still goes through the
  fixed parser and never depends on the region. The messages about a refused amount name the point, which
  every region accepts.
- **This adds** scales prefilled barcode, label or Library nutrients live from the typed amount, using the
  totals builder's basis rules and the same metric components Save stores. Energy comes first. A nutrient the
  product does not state gets no line; a "does not apply" value keeps its line. A basis that
  cannot be resolved leaves every line unknown; zero is never shown for unknown. Invalid amount text shows
  no preview lines, and a form without prefilled nutrients hides the section.
- **Details layout** uses a header card for Name, known Brand, Kind and the typed barcode lookup; Amount
  and Unit share a row, followed by the serving hint, Meal and When. All values is collapsed initially and
  contains the full prefilled list, additional label rows and source text with a titled licence link when
  available. Library products say "From your Library"; an unedited recipe keeps its version snapshot.
  Save stays enabled in the bottom inset, with save errors and blocked-field messages above it. Serving
  chips and Log to several days are disabled placeholders with Later badges and "Not available yet".
- **Local day**: an intake is on Today when its time falls on the same calendar day as "now" in the intake's own time
  zone. Deleted intakes are hidden. A time corrected on the entry screen moves the entry to the day it now falls on,
  in the Journal as well as here.
- **Date subtitle** uses the current device time zone on every reload, including after a zone change.
- **Missing values**: a food snapshot with only unknown tracked nutrients counts as having no nutrition values.
  Goal-bar reasons count intakes, not components. An entry whose nutrient is not applicable does not make that
  nutrient logged; a day containing only such entries reads "Nothing logged yet" for that nutrient.
- **Water total** is the exact `Decimal` sum, in mL, of the volume components of intakes with category `water`. Other
  categories never contribute, whatever their unit. A component whose unit is not a volume is skipped and counted
  (`waterSkippedCount`), never treated as zero. So is a stored amount that is NaN or not above zero, checked before and
  after conversion to mL.
- **Invalid time zone**: a stored intake whose time zone identifier is not a valid time zone is left out of Today (no
  row, not in the water total or coverage) and counted in `skippedIntakeCount`, which is reset on each load. There is no
  fallback to the current time zone for stored intakes.

## Units and the quick-water amount

Two display preferences live in `ios/NutritionCore/Sources/NutritionUI/DisplayPreferences.swift`:
`UnitSystem` (metric, or the US system offering `oz` and `fl oz`) and the quick-water amount, stored in
mL. The defaults are metric and 250 mL. `UserDefaultsDisplayPreferences` persists them under namespaced
`display.` keys, written synchronously; `InMemoryDisplayPreferences` is the in-memory implementation for
tests. The app builds one `UserDefaultsDisplayPreferences` in `AppServices` and passes it to every screen,
so a change made on one screen is read by the next.

Where they are set: **Settings > Units and logging**, reached from the gear on every tab.
`AppSettingsView` composes `AppSettingsViewModel` and the existing `ConnectionsPrivacyViewModel`.
The segmented unit-system picker and inline quick-water field save on submit or focus loss, without a Save button. The field is **read in the preferred unit** —
`fl oz` under the US system, `mL` under metric — and its label says which one, so twelve means twelve
fluid ounces and not twelve millilitres. The helper line under it states the amount **in the field** in
the other unit (`= 355 mL`), read from the draft rather than from what was last saved, so a figure typed
and not yet stored already says what it is worth. Changing the unit system restates an amount already
typed in the new unit. The amount
is validated with the same POSIX parser as Add intake and must be above zero; anything else is refused
with a message and the stored value is left alone. What is **stored** stays millilitres: `save` converts
a typed fluid-ounce figure by the exact factor (× 29.5735295625, exact in a `Decimal`), so 12 fl oz is
stored as 354.88235475 mL and the Today button reads back `12 fl oz`. A converted draft is rounded to the
digits the field shows before it is written back, so 250 mL shown as `8.45 fl oz` and saved stores
249.896324803125 mL — the glass those digits stand for. Metric shows the stored millilitres unrounded,
so `400.55` stays `400.55` in the field.

What the preference changes, and what it does not:

- **Offered**: the Add-intake `Picker("Unit")` lists the registry's whole set for metric, and `oz` and
  `fl oz` first for the US system. Both are always available. The counted units are the registry's too, so
  a supplement can be logged in `gummy` or `piece` alongside `capsule`, `tablet`, `scoop` and `serving`.
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

## Goal bars
`TodayViewModel.goalBars` holds one `GoalBarModel` per tracked nutrient except water, in tracked order, and
`waterBar` holds water's when a water goal is set. `NutrientProgressLine.text` and `CoverageLine.text` still exist
and are still tested, but Today no longer prints them. A bar is in one of five states, decided from what the day
holds because an empty day and an unreadable one are both `.unknown`:

| State | When | Figure | Bar |
|---|---|---|---|
| progress | known total, goal not exceeded | "52 g of 60 g" | accent fill to the fraction |
| overGoal | known total above the goal | the real figure, "262 g of 230 g" | full bar with a notch at goal over total |
| noGoal | known total, no goal | "1150 mg" | none |
| cannotTotal | entries exist and the total is unknown | "Can't total yet" | hatched track, never a fraction |
| nothingLogged | no food or drink entry could contribute (for water, no water entry) | "Nothing logged yet" | empty track |

Nothing logged is not a total of zero: a known zero reads "0 g of 60 g" with an empty fill. Fractions are `Decimal`,
clamped to 0 through 1; `GoalBar.drawingWidth` is the one place one becomes a `Double`. The bar is a single
accessibility element and never colour alone. Progress is always the accent colour: green and red belong to the
state of the app, not of the day.

The reason line under a cannot-total bar says "N entries have no <nutrient> value" only where `CoverageLine`
reports missing entries for that nutrient, and otherwise "Some entries can't be added up for <nutrient>" (a
below-threshold bound, an unresolvable basis). For water it is the sentence about entries that are not a volume.

## Missing values line
The Coverage section is gone from Today. `missingValuesSummary` is one line, "2 entries have no nutrition values",
counting food and drink entries whose product snapshot states nothing and whose components the lookup knows nothing
about for any tracked nutrient. Supplements and water are never counted: stating no macros is what a supplement is.
Nil when there are none. Water is left out of the per-nutrient reason lines for the same reason it was left out of
Coverage: its entries are the only ones that could say anything about it.

## Unknown is not zero
Values come from an injected `NutrientFactsLookup`. The default, `UnknownNutrientFacts`, always answers `.unknown`
because there is no catalog yet. An unknown value counts as missing. A known zero is known, so it is not missing.
Not-applicable values are left out of both numbers. Below-reporting-threshold values count in the total but are not
missing — in a *total* they are a different matter, and make the nutrient uncertain (see Totals above).

The app injects `SnapshotNutrientFacts`, which answers from the nutrient values the entry's product snapshot carries.
A snapshot is read at most once per load however many components and nutrients refer to it, and one that cannot be read
is treated as absent, which reads as unknown rather than as zero. The values are the product's own, on the basis its
snapshot names: coverage asks only whether a value is known, and the stored value is never scaled to the component's
amount. Each value is read through the canonical nutrient mapping's keys, so a snapshot storing `energyKcal` counts
as known for `energy` rather than as missing. An entry typed by hand has no snapshot, so it stays unknown until a product or a calculated recipe is attached.

## Boundaries
`NutritionUI` imports no HealthKit and no networking. Colours come only from the design tokens through
`TokenColors.swift`; text uses Dynamic Type styles; every button and image has an accessibility label.

Totals and goals are read and written, and neither is delivered anywhere: a target is not an intake, and the export
carries neither. What the totals above imply is deliberately absent — nothing is persisted, so every figure is
recomputed on each load; there is no scope other than a single day, so there is no week or month view and no
carry-over; and a single unresolvable entry makes its whole nutrient unknown, which hides the entries beside it.
Those are the open parts of `docs/mvp-gaps-traceability.md` rows 1 and 7.
