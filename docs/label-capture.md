# Label capture: scan, parse, confirm, save

Status: the parser, the review screen and the capture sheet are in place. Terms review date: 2027-10-04.

Label capture (issue #39, review screen in #61) reads a US Nutrition Facts panel from a photo and turns
it into an intake the user confirms. This note describes the whole flow and what the parser in the
middle of it does and does not do, and what the review screen asks the user about before anything is
filled in.

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
3. **Confirm.** The review screen shows the panel as it was read, marks every value the parser read
   with less than full confidence, and lets the user confirm or correct any row. Nothing is filled into
   the intake form while a marked value is still unanswered.
4. **Save.** Only what the user confirmed is written to the journal. A value the parser could not read,
   and a value the user did not agree with, is never saved on the parser's word.

Nothing in this flow saves anything by itself. The parser is a pure function over text, so the only way
a scanned number reaches the journal is through a confirmation the user gave.

The camera lives in the app target (`LabelCaptureSheet.swift`), never in the UI package: it uses
VisionKit's `DataScannerViewController` with `recognizedDataTypes: [.text()]`, checks `isSupported` and
`isAvailable` before offering the entry, and a Capture button collects the recognized lines in reading
order — top to bottom, and left to right within one line of print, so a two-column panel reads as the
rows it printed. `NutritionUI` sees only `[String]`.

## What the parser handles

- **The panel as it is printed.** `Nutrition Facts`, `Amount per serving`, the footnote and the
  surrounding print are recognised as lines that state nothing and are ignored.
- **The serving size**, as printed (`1 cup (240mL)`, `3/4 cup (55g)`), plus the measure it states when it
  states one: the amount in parentheses becomes a `Quantity`, and `servingsPerContainer` is read whether
  the count stands before the phrase ("About 6 servings per container") or after it.
- **The fifteen nutrient rows** the journal names, in the order a panel states them, including the
  indented breakdown rows: saturated fat and trans fat under total fat, dietary fiber and total sugars
  under total carbohydrate, added sugars under total sugars.
- **Amounts stated in front of the name**, as `Includes 5g Added Sugars` states them. A leading amount
  states its own unit like any other amount, and a number in front of a percent sign belongs to a Daily
  Value column rather than to the row.
- **Amounts split across lines**, as a column-by-column capture produces them, and several rows flattened
  onto one line. On a flattened line a row the parser cannot read stays unknown and the rows after it are
  still read, a Daily Value is only removed from the row that printed it, and an `Includes` belongs to the
  row it qualifies.
- **Grouped thousands**: `1,000` is one thousand and `12,500` is twelve thousand five hundred.
- **Unit spelling noise**: `140mg` and `140 mg` read the same, and `µg`, `μg` and `mcg` are one mass and
  become `mcg`.
- **A letter `O` where a zero belongs** — `1O mg`, `O g`, `O.5g` — which is read as the zero it is.
- **Bounds.** `Less than 1g` and `<1g` become `.belowReportingThreshold`, keeping their unit.

## What the parser never guesses

- **A missing row is `.unknown`, never zero.** A panel that says nothing about potassium does not say
  potassium is zero. Unknown is a different state from a stated zero, and it is the state the
  confirmation screen shows as "not read".
- **The % Daily Value column is never an amount.** Only a number that stands on its own, on the row that
  printed it, becomes a value. A bare number on a row that prints no unit of its own — the Calories row
  is the only one — is read there and nowhere else, because everywhere else a bare number is a Daily
  Value column or a row that lost its unit.
- **An ambiguous thousands separator is never a smaller number.** A comma is only read as grouping
  thousands when the first group is one to three digits and every group after it is exactly three, as in
  `1,000` and `12,500`. `1,8` and `1,00` are ambiguous, so the row keeps no amount at all rather than
  the number the digits before the comma spell.
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

The serving size carries its own reasons in `ParsedServingSize.review`, because the serving size scales
every nutrient saved from the panel: a `Serving size 1 cup (24O mL)` reads as `240 mL` and is highlighted
as corrected rather than being quietly scaled by a number the parser fixed up.

A row with no reason was read exactly as printed. The reasons are a prompt to ask, never a correction
the parser applies on its own: the user confirms the value, corrects it, or drops the row.

## The review screen

`LabelCaptureViewModel` sits between the parser and the intake form. It holds one row per nutrient,
the value the parser read, and what the user has done about it. `LabelCaptureView` shows those rows;
`LabelCaptureSheet` in the app target owns the camera and hands the scanner's lines over.

The rules the screen keeps are short:

- **A row the parser flagged has to be answered.** `canApply` is false while any flagged row is still
  `.needsConfirmation`, and so is `makeProduct()`. The user either taps Confirm, which accepts the
  value as printed, or taps Correct and types their own. There is no third way to get a flagged value
  saved on the parser's word.
- **A flagged serving size blocks the same way.** The serving size scales every nutrient below it, so
  a `Serving size 1 cup (24O mL)` the parser corrected is confirmed separately, exactly like a row.
- **A correction is checked with the same amount parser the intake form uses.** `AmountParser.parse`
  accepts digits and at most one point; anything else is refused, changes nothing and says why. A
  correction keeps the unit the panel printed, so it never moves a value between units: a row printed
  in mg stays in mg, and a row the panel printed no unit for is corrected in the unit that row usually
  carries.
- **A nutrient the panel does not state stays `.unknown`.** It is shown as "not on the panel" and is
  left out of the product rather than stored as zero, so `ProductDefinition.value(for:)` reads it back
  as unknown.
- **A panel with no readable amount is not turned into a product.** `isUnreadable` is true, the screen
  says the panel could not be read, nothing is filled in, and the only thing offered is another look at
  the panel.

The product the review screen hands on records `catalogOrigin` as `label_capture` and its basis as
`per serving`, with the serving spelled out when the panel stated a measure (`per serving (240 mL)`) and
as printed when it stated only a household word (`per serving (1 large biscuit)`). The snapshot carries
only the known, answered values.

`AddIntakeViewModel.applyLabelProduct(_:)` then fills the form the way a barcode lookup fills it: the
nutrients and the serving are attached, the product is written as the snapshot on save, and the name is
left for the user, because a panel states nutrients rather than what the food is called. A captured
product is invalidated by exactly the same things a looked-up one is: a later barcode, a later lookup
or another capture clears the values and the snapshot together.

## Privacy: no image is stored or sent

Text recognition runs on the device and nothing leaves it:

- **No image is stored, and none is sent anywhere.** The scanner reads text; the camera's frames and
  any crop of one are never written down and never uploaded. `LabelCaptureSession` keeps the
  transcripts of the items the camera currently recognizes, and each frame replaces the last.
- **Nothing goes over the network.** Label capture makes no request. The `catalogOrigin` recorded with
  the entry says where the values came from, and that is a panel the user read on their own device.
- **Only the panel's text enters the app.** What is stored with the entry is the nutrient values and
  the serving, which is what the user chose to record.
- **The camera is used only for this.** The existing camera usage description already covers it, so no
  new Info.plist key is needed.

## What is not here yet

- Panels that are not US Nutrition Facts panels: a supplement facts panel, a menu item or a non-US
  label is out of scope for this parser.
- Reading more than one panel in one capture: the sheet reads what is in the frame.
