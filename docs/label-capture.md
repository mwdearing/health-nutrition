# Label capture: scan, parse, confirm, save

Status: the parser is in place. The camera and the screen are not. Terms review date: 2027-10-04.

Label capture (issue #39) reads a US Nutrition Facts panel from a photo and turns it into an intake the
user confirms. This note describes the whole flow and what the parser that sits in the middle of it
does and does not do. The parser is built and tested; the capture session and the confirmation screen
are later work.

## The flow

1. **Scan.** A capture session frames the panel and produces one text line per line of text it can see.
   How it gets those lines is not this parser's business: it takes `[String]` and nothing else, so the
   same parser reads a live camera, a photo from the library or a fixture in a test.
2. **Parse.** `NutritionFactsParser.parse(lines:)` returns a `ParsedNutritionFacts`: the serving size, the
   servings per container, and one `NutrientValue` per nutrient the panel states, keyed with the names
   the journal already uses (`energyKcal`, `fat`, `saturatedFat`, `transFat`, `cholesterol`, `sodium`,
   `carbohydrates`, `fiber`, `sugars`, `addedSugars`, `protein`, `vitaminD`, `calcium`, `iron`,
   `potassium`). Every amount is read exactly with `Decimal(string:)` and keeps the unit the label
   printed (`kcal`, `g`, `mg`, `mcg`).
3. **Confirm.** The screen shows the panel as it was read, marks every value the parser read with less
   than full confidence, and lets the user correct or drop any row.
4. **Save.** Only what the user confirmed is written to the journal. A value the parser could not read,
   and a value the user did not agree with, is never saved on the parser's word.

Nothing in this flow saves anything by itself. The parser is a pure function over text, so the only way
a scanned number reaches the journal is through a confirmation the user gave.

## What the parser handles

- **The panel as it is printed.** `Nutrition Facts`, `Amount per serving`, the footnote and the
  surrounding print are recognised as lines that state nothing and are ignored.
- **The serving size**, as printed (`1 cup (240mL)`, `3/4 cup (55g)`), plus the measure it states when it
  states one: the amount in parentheses becomes a `Quantity`, and `servingsPerContainer` is read whether
  the count stands before the phrase ("About 6 servings per container") or after it.
- **The fifteen nutrient rows** the journal names, in the order a panel states them, including the
  indented breakdown rows: saturated fat and trans fat under total fat, dietary fiber and total sugars
  under total carbohydrate, added sugars under total sugars.
- **Amounts stated in front of the name**, as `Includes 5g Added Sugars` states them.
- **Amounts split across lines**, as a column-by-column capture produces them, and several rows flattened
  onto one line.
- **Unit spelling noise**: `140mg` and `140 mg` read the same, and `µg`, `μg` and `mcg` are one mass and
  become `mcg`.
- **A letter `O` where a zero belongs** — `1O mg`, `O g` — which is read as the zero it is.
- **Bounds.** `Less than 1g` and `<1g` become `.belowReportingThreshold`, keeping their unit.

## What the parser never guesses

- **A missing row is `.unknown`, never zero.** A panel that says nothing about potassium does not say
  potassium is zero. Unknown is a different state from a stated zero, and it is the state the
  confirmation screen shows as "not read".
- **The % Daily Value column is never an amount.** Only a number that stands on its own, on the row that
  printed it, becomes a value. A bare number on a row that prints no unit of its own — the Calories row
  is the only one — is read there and nowhere else, because everywhere else a bare number is a Daily
  Value column or a row that lost its unit.
- **A bound is never an amount.** `Less than 2g` is not 2 g of anything.
- **A unit outside the registry is never resolved into one inside it.** A row the parser cannot read
  stays `.unknown` instead of being pulled towards the unit that nutrient usually carries.
- **A nutrient printed in a unit it does not usually carry keeps that unit.** `Total Fat 120mg` is read
  as 120 mg, not quietly rewritten to the nearest number of grams.
- **A household word is not a measure.** `Serving size 1 large biscuit` keeps its text and states no
  quantity, because the label states none.
- **Nothing is inferred from another row.** Trans fat stated inside saturated fat stays part of that
  line; the parser does not promote it to a row of its own.

## Values that need review

Every value the parser had to touch carries the reason, in `valuesNeedingReview`, so the confirmation
screen can highlight exactly those rows instead of asking the user to check the whole panel:

| Reason | Meaning |
| --- | --- |
| `correctedLetterO` | A letter `O` stood where a zero belongs, so the printed text was corrected. |
| `unexpectedUnit` | The row carries a unit this nutrient does not usually carry; the amount is kept as printed. |
| `normalisedMicrogramSymbol` | A microgram symbol was written `µg`, `μg` or `ug` and became `mcg`. |

A row with no reason was read exactly as printed. The reasons are a prompt to ask, never a correction
the parser applies on its own: the user confirms the value, corrects it, or drops the row.

## What is not here yet

- The capture session that produces the lines. `NutritionFactsParser` takes text and has no image, camera
  or framework dependency, so that part can change without touching it.
- The confirmation screen, and the write into the journal.
- Panels that are not US Nutrition Facts panels: a supplement facts panel, a menu item or a
  non-US label is out of scope for this parser.
