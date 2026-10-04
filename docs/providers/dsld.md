# NIH DSLD label import

Status: Accepted for reading a recorded label. Terms review date: 2027-10-02.

## What this adapter is

`DSLDLabelAdapter` turns one recorded NIH Dietary Supplement Label Database (DSLD) label response into
`NutritionDomain` values: `Data` in, a `DSLDSupplementLabel` out. It is pure parsing. It sends no
requests, opens no sessions and caches nothing; a live DSLD client is a separate piece of work and will
feed this adapter the same bytes.

The adapter reads a label for its own serving size. DSLD states each ingredient row for one serving size
and the adapter keeps that basis; it does not normalise to 100 g and it does not rescale.

## Field mapping

| DSLD JSON | Domain value | Rule |
| --- | --- | --- |
| `id` | `DSLDSupplementLabel.id` (`Int`) | Required. A missing or unreadable id throws `DSLDAdapterError.missingIdentifier`. |
| `fullName` | `fullName` | Falls back to `brandName`, then to empty text. Never invented. |
| `brandName` | `brandName` | Empty text when absent. |
| `offMarket` | `offMarket` (`Bool`) | `1` is true, `0` is false. Absent or unreadable is false. |
| `servingSizes[]` | `servingSizes` (`DSLDServingSize`, wrapping `Quantity`) | `order` becomes the serving-size order, `minQuantity`/`maxQuantity` with the registry unit of `unit` when the registry knows it, otherwise a count of `.serving`; the original text stays in `unitText`. `inSFB` becomes `isFactsPanelServing`. |
| `ingredientRows[]` | `facts` (`CompoundFact`) | One fact per row that is not a blend, for the first serving size. |
| `servings` (`DSLDServingFacts`) | `servings` | The facts and blends of every serving size the label lists, each with its `servingSizeOrder` and its `DSLDServingSize`. `facts` and `blends` are only the first entry. |
| `ingredientRows[].ingredientId` | `substanceIdentifier` | The DSLD ingredient id, kept as text whether the source writes it as a JSON number or a string; the row name is the fallback. |
| `ingredientRows[].order` | provenance only | Kept in the provenance text so the row stays traceable. |
| `ingredientRows[].name` | `labelName` | A row with no name is skipped, because a fact without a name cannot be shown. |
| `ingredientRows[].forms[].name` | `chemicalForm` | The first form name the row states, for example "Magnesium Citrate". |
| `ingredientRows[].quantity[]` | `amount` (`NutrientValue`) | The entry whose `servingSizeOrder` matches the serving size being read; see the amount rules below. |
| `category` is `blend`, or the name or ingredient group says "Proprietary Blend" | `blends` (`ProprietaryBlend`) | The row amount is the blend total and the nested rows are the members. A blend total is not repeated in `facts`. The blend identifier is `dsld-<label id>-<row order>-<ingredient id>`, so two blend rows of one label never collide and no blend is dropped from identifier-based totals. |
| `ingredientRows[].nestedRows[]` of an ordinary nutrient | further `facts` | Nesting alone is not blend metadata: DSLD also nests a nutrient under its own breakdown (Folate with Folic Acid, Calories with Calories from Fat). The parent stays a fact and the child becomes a fact of its own, with its own identifier and amount. |
| `ingredientRows[].nestedRows[]` of a blend | `blends[].members` (`BlendMember`) | A nested row that states an amount keeps it; a nested row with no amount is `.unknown`. |
| `ingredientRows[].category`, `notes` | not mapped | Free text kept by DSLD for display; the app does not read them. |

## Amount rules

- An entry is `.known` only when all of the following hold: the row carries a quantity entry, the entry
  carries a number, that number is greater than zero, the operator is `=`, and the unit is one the table
  below covers.
- **Unknown is never zero.** A missing entry, a missing number, a stated zero, a missing operator and a
  unit outside the table all read as `.unknown`. A label that does not state an amount does not state
  that the amount is nil.
- **Only `=` states an exact amount.** A `<` row with a unit the table covers becomes
  `.belowReportingThreshold` and keeps that unit, because the label states a bound and not an amount. A
  `<` row whose unit is not in the table becomes `.unknown`, because a bound without a unit carries no
  dimension to interpret it with. Any other operator, including `>` and a missing operator, becomes
  `.unknown`. A bound never becomes a known exact amount.
- Blend members are usually undisclosed and read as `.unknown`. A member amount is never inferred from
  the blend total, and the total is never divided among the members.

## Serving sizes

- DSLD states each ingredient row once per serving size and names the serving size in `servingSizeOrder`.
  The adapter reads every serving size the label speaks of — the ones in `servingSizes[]` and the ones its
  quantity entries name — and keeps one `DSLDServingFacts` per order in `servings`.
- An amount is never taken from a different serving size than the one being read. A row that states no
  entry for a serving size is `.unknown` for that serving size, not the amount of the first one.
- `facts` and `blends` are the first serving size, kept for the common single-serving label;
  `serving(_:)` looks a serving size up by order and returns nil when the label does not state it.

## Basis rules

- Every listed ingredient row becomes a `.nutrient` fact on the `.activeNutrientMass` basis with role
  `.contextOnly`, including international-unit rows, which keep their own basis as an amount and never
  a mass.
- `forms` records the source form only. A row such as Magnesium 400 mg "as Magnesium Citrate" or Calcium
  1200 mg "as Calcium Carbonate" states the amount of the listed nutrient; the adapter keeps
  `chemicalForm` but does **not** infer a `.compoundMass` basis from the presence of a form, so
  active-nutrient totals include ordinary vitamins and minerals instead of demanding an equivalence
  factor the label does not provide.
- A blend total is `.compoundMass`, because that is what a proprietary blend total states.
- A row never becomes a `.compound` fact from this source: DSLD does not distinguish a compound mass from
  an active-nutrient mass on the Supplement Facts panel.

### Units

| DSLD unit text | Domain unit |
| --- | --- |
| `mg` | `.mg` |
| `mcg`, `µg` (U+00B5), `μg` (U+03BC) | `.mcg` |
| `g` | `.g` |
| `IU` | `.iu` |

Every other unit text DSLD writes, for example `NP`, `Gram(s)`, `Calorie(s)`, `{Calories}` and
`mcg DFE`, has no canonical registry unit and is read as `.unknown` rather than guessed into one. A
future release may add a unit to the table; it must never drop one silently.

IU is kept as an international unit. The domain refuses to convert an international unit to a mass, and
the adapter never does it either.

### Numbers are exact

Every amount is read from the literal text of its JSON number and turned into a `Decimal` with
`Decimal(string:)`. `JSONSerialization` and `JSONDecoder` are not used for numbers: `JSONSerialization`
hands numbers over as `NSNumber`, which routes them through a binary floating point type, and
`JSONDecoder` does the same for `Decimal`. A tiny JSON reader (`DSLDJSONReader`) keeps number literals
as text instead, so `0.1` stays `0.1` and `2.5` stays `2.5`. The same literal text is what
`ingredientId` and `order` are read from, so a numeric identifier stays the DSLD identifier.

The reader only accepts well-formed JSON. It rejects a number with a leading zero (`01`), a string that
contains an unescaped control character below U+0020, and bytes that are not well-formed UTF-8, rather
than passing them on with a substituted character. Positions in `malformedJSON` are absolute byte
offsets into the document.

A literal that a `Decimal` cannot hold exactly is rejected as `malformedJSON` rather than rounded:
`Decimal(string:)` succeeds after rounding for a literal with more than 38 significant digits or with an
adjusted exponent outside ±127, and publishing that rounded value as a known amount would break the
exactness this adapter promises.

## Malformed input

Malformed input throws `DSLDAdapterError`:

- `malformedJSON(reason:offset:)` when the bytes are not well-formed JSON.
- `notAnObject` when the document is well-formed JSON but not an object.
- `missingIdentifier` when the label has no usable `id`.
- `missingIngredientRows` when the label has no `ingredientRows` array.

A label that is well formed but incomplete is not an error: a missing name, unit or amount is `unknown`.

## Licences

- The NIH Dietary Supplement Label Database is released under the
  [CC0 1.0 Universal licence](https://creativecommons.org/publicdomain/zero/1.0/), so the recorded
  label data in `contracts/providers/dsld` is public domain and carries no share-alike or attribution
  obligation.
- Product images and PDF documents are deliberately not part of the fixtures and the adapter has no
  field for them. Including them would need a separate licence review.
- A label in the fixtures is an API snapshot used for testing. It is not an endorsement of the product
  by the NIH, the Office of Dietary Supplements or the app.

## Fixtures and tests

The recorded labels live in `contracts/providers/dsld`, with `MANIFEST.json` listing every file, its
SHA-256 and its coverage metadata. `DSLDLabelAdapterTests` reads the manifest from the repository root,
found relative to `#filePath`, and parses every recorded label; no fixture is copied into the test
bundle and no test touches the network.

## Review

Re-read the DSLD API documentation and the CC0 terms by 2027-10-02, or sooner if they change, and update
this note.