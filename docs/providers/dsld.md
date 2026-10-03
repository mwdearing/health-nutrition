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
| `servingSizes[]` | `servingSizes` (`DSLDServingSize`, wrapping `Quantity`) | `minQuantity`/`maxQuantity` with the registry unit of `unit` when the registry knows it, otherwise a count of `.serving`; the original text stays in `unitText`. `inSFB` becomes `isFactsPanelServing`. |
| `ingredientRows[]` | `facts` (`CompoundFact`) | One fact per row that is not a blend, on the per-serving basis the row states. |
| `ingredientRows[].ingredientId` | `substanceIdentifier` | The DSLD ingredient id as text; the row name is the fallback. |
| `ingredientRows[].name` | `labelName` | A row with no name is skipped, because a fact without a name cannot be shown. |
| `ingredientRows[].forms[].name` | `chemicalForm` | The first form name the row states, for example "Magnesium Citrate". |
| `ingredientRows[].quantity[]` | `amount` (`NutrientValue`) | The entry for the first serving size; see the amount rules below. |
| rows named "Proprietary Blend" or rows with `nestedRows` | `blends` (`ProprietaryBlend`) | The row amount is the blend total and the nested rows are the members. A blend total is not repeated in `facts`. |
| `ingredientRows[].nestedRows[]` | `blends[].members` (`BlendMember`) | A nested row that states an amount keeps it; a nested row with no amount is `.unknown`. |
| `ingredientRows[].category`, `notes` | not mapped | Free text kept by DSLD for display; the app does not read them. |

## Amount rules

- An entry is `.known` only when all of the following hold: the row carries a quantity entry, the entry
  carries a number, that number is greater than zero, the operator is `=`, and the unit is one the table
  below covers.
- **Unknown is never zero.** A missing entry, a missing number, a stated zero, a missing operator and a
  unit outside the table all read as `.unknown`. A label that does not state an amount does not state
  that the amount is nil.
- **Only `=` states an exact amount.** A `<` row becomes `.belowReportingThreshold` and keeps its unit,
  because the label states a bound and not an amount. Any other operator, including `>` and a missing
  operator, becomes `.unknown`. A bound never becomes a known exact amount.
- Blend members are usually undisclosed and read as `.unknown`. A member amount is never inferred from
  the blend total, and the total is never divided among the members.

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
as text instead, so `0.1` stays `0.1` and `2.5` stays `2.5`.

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