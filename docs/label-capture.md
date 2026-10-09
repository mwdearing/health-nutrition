# Label capture: scan, parse, confirm, save

Status: the parser, the review screen and the capture sheet are in place. Terms review date: 2027-10-04.

Label capture (issue #39, review screen in #61) reads a US Nutrition Facts panel from a photo and turns
it into an intake the user confirms. This note describes the whole flow and what the parser in the
middle of it does and does not do, and what the review screen asks the user about before anything is
filled in.

## Add flow

The shared **Add food or drink** action opens Add home in a full-screen cover with one
navigation stack and Cancel. **Add to Lunch** (and the other meal sections on Today) opens
the same home with that meal selected. None, Breakfast, Lunch, Dinner and Snack are explicit
choices; the selected meal is carried into barcode, label, Library and typed Details.

The four methods are **Scan barcode**, **Scan label**, **From Library** and **Type it in**.
Scanners are pushed destinations, not nested sheets. An unavailable scanner stays visible
with an explanation and a typed alternative. A scanned barcode starts the lookup immediately;
typing digits in Details still requires **Look up**. A missing product or a product with no
nutrition facts offers **Scan the label instead** and **Type it in**.

Label capture keeps its existing on-device camera, multi-photo review and confirmation
behavior. **Use these values** pushes the existing Details form; it does not save an entry. While
values are still waiting for an answer the same button reads **Confirm 1 value first** or
**Confirm N values first**, with N the count still owed, and stays disabled until the count is zero.
A capture with nothing readable keeps the plain title and stays disabled; it asks for another photo, not a confirmation.
Library pick mode offers Favourites, Recent and Recipes. Picking prefills Details without
switching tabs or writing the journal. Save closes Add and clears its path; Cancel does the same.

Home shows at most five recent items from the journal. Each quiet **Add** action logs
immediately with the currently selected meal and shows an Undo toast for ten seconds.
Undo removes only that new entry. Without recent items, home says
"Things you log will show up here."

**Search foods**, **Describe or photograph a meal** (#149) and **Amounts only** (#146)
remain disabled, carry a Later badge, and announce "Not available yet".

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
VisionKit's `DataScannerViewController` with `recognizedDataTypes: [.text()]` and
`recognizesMultipleItems` on, because a panel is printed as many separate items and asking for one at a
time caps what the scanner reports. It checks `isSupported` and `isAvailable` before enabling the tile,
and a Capture button collects the recognized lines in reading order — top to bottom, and left to right
within one line of print, so a two-column panel reads as the rows it printed. The held lines are replaced
on every change to the recognized set, including a removal, so Capture submits the frame in front of the
camera rather than the last frame that had anything on it. `NutritionUI` sees only `[String]`.

## What the parser handles

- **The panel as it is printed.** `Nutrition Facts`, `Amount per serving`, the footnote and the
  surrounding print are recognised as lines that state nothing and are ignored.
- **Which panel it was.** A `Supplement Facts` heading makes the capture a **supplement**, and anything
  else — a `Nutrition Facts` panel, or a heading that was cropped out of the frame — makes it a **food**.
  The heading is what decides it, not the rows: a supplement prints Vitamin D, Calcium and Potassium
  under the same names a food does, so the rows cannot tell the two apart. The kind is carried on
  `ParsedNutritionFacts.panelKind` and set on the saved snapshot, where it is what later keeps a
  multivitamin out of the day's count of foods. Losing the heading costs the label its kind and nothing
  else — every value read from it is kept exactly as before — and the review screen lets the user change
  the kind, which is what a powder that prints a Nutrition Facts panel anyway needs.
- **The serving size**, as printed (`1 cup (240mL)`, `3/4 cup (55g)`), plus the measure it states when it
  states one: the amount in parentheses becomes a `Quantity`, and `servingsPerContainer` is read whether
  the count stands before the phrase ("About 6 servings per container") or after it.
- **The fifteen nutrient rows** the journal names, in the order a panel states them, including the
  indented breakdown rows: saturated fat and trans fat under total fat, dietary fiber and total sugars
  under total carbohydrate, added sugars under total sugars.
- **The compound rows a supplement panel adds.** A supplement states its own compounds — `Creatine
  Monohydrate 3g`, `Zinc 15mg`, `Coenzyme Q10 100mg` — and they are why anyone scans one, so every
  `Name amount unit` row the fifteen journal nutrients do not name is kept as an **additional
  nutrient**, under the name the label printed and a slug of that name (`creatine-monohydrate`). The
  name is one to four words of letters and digits and the unit has to be `g`, `mg`, `mcg` or `IU` (which
  is read spelled `iu` as well), which is what a panel states a compound in; a count is not one, because
  a panel states no compound per gummy. The `†` and `%DV` columns the label prints beside a row are not
  part of its amount. A column-by-column capture that leaves the name on one line and its amount on the
  next (`Creatine Monohydrate` / `3g`) is one row, exactly as a named nutrient row split across lines
  is. Text that states no amount is never a row: an ingredients line, a footnote, a lot number and a
  phone number are print, and a packaging quantity (`NET WT 100 g`, `Net weight`, `Lot`, `Best by`) is
  print too. A row the table above already read is never collected a second time — `Vitamin D3 25mcg`
  is the journal's vitamin D, and its alias carries the `3` so it is not also stored as a compound.
  A name that states its chemical form builds on the nutrient it is built from: `Calcium Citrate 200mg`
  is calcium and `Iron Bisglycinate 25mg` is iron, recorded as that nutrient with the printed form kept
  as the row's display name, rather than the search restarting inside the name and inventing `Citrate`
  or `Bisglycinate` as compounds of their own.
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
  confirmation screen shows as "Not on the label".
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

These names are the parser's own enum and are never shown. The review screen words the reasons in
plain English: `correctedLetterO` reads "a letter O was read as a zero", `unexpectedUnit` reads "the
unit is not the one this row usually carries", and `normalisedMicrogramSymbol` reads "the unit was read
as mcg". The reasons are gathered under "Check this value:" on the row.

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
  a `Serving size 1 cup (24O mL)` the parser corrected is confirmed separately, exactly like a row. The
  question asked about it is plain: "We read this as 240 mL. Is that right?". It names the quantity the
  parser settled on when there is one, and otherwise the serving as printed (`this serving size` when the model
  holds no serving text).
- **A panel that stated no serving size cannot be used until the user states one.** Values read from a
  panel are per serving, and one serving may be 30 g, 250 mL or one item, so a capture that missed the
  serving-size line would otherwise be stored as a bare `per serving` with numbers nothing can scale. The
  screen asks for it in an amount with its unit — `30 g`, `240 mL` — and refuses a number without one or a
  household word on its own, because that would leave the values exactly as unscalable as they were. Once
  it is stated the basis reads `per serving (30 g)`, the same spelling a panel that stated its own serving
  gets. A serving size the panel printed as words alone (`Serving size 1 large biscuit`) is shown as it was
  printed rather than asked for: the panel's own words are what the user checks, and the basis carries them.
- **A printed serving size can be corrected, like a nutrient row.** The printed line is read text, so it is
  as easy to misread as any row, and it scales everything below it besides. Correcting it takes the same
  amount-with-its-unit form (`30 g`), has no dimension to agree with — a serving may be weighed, poured or
  counted — and stands as an answer: the parser's question about it is answered either way. The control is
  hidden when there is no serving to correct, which is the case for a panel that stated none.
- **A counted serving reads with the words a label uses, on both paths.** `Serving size 3 gummies` and
  `Serving size 2 pieces` become counts, singular or plural, because the number decides the wording and
  neither spelling is a different unit. A serving size **entered by hand** is read with the same table
  (`NutritionFactsParser.countedUnit(for:)`), so `3 gummies` typed into the field means what it means on the
  panel; a word outside the table is still refused.
- **Every row the parser read an amount for can be corrected, not only a flagged one.** Recognition can
  read one valid number as another valid one — `180` as `130` — and then the parser records no reason,
  because the transcript is perfectly well formed. The row is still wrong, so the screen offers the same
  Correct control whether the parser asked about the row or not. A row the panel did not state has no
  amount to correct and is shown as unknown; a bound is a limit rather than a number, so it is read or
  not read and the panel's own words stand.
- **A correction is checked with `NutrientAmountParser`, which accepts zero.** That is the one rule on
  which it differs from the intake form's `AmountParser`: a panel states `0g` often and legitimately,
  and `NutrientValue.known(0, unit)` is what such a row means, while an intake of nothing is not an
  entry. Everything else stays as strict as the form — digits with at most one point, no sign, no locale
  and no grouping. The unit is optional: text that names none keeps the unit the panel printed, and text
  that names one is read as that unit.
- **A correction's unit has to be of the nutrient's own dimension.** Another unit of the same kind is
  fine, so a sodium row printed in mg may be restated as g; a litre of sodium or a gram of calories is
  refused, because nothing downstream can interpret a value in the wrong dimension and would drop it in
  silence. The dimension is the **nutrient's expected** one, not the unit a particular capture happened to
  read: the printed unit is sometimes the reason the row was flagged in the first place, so following it
  would let a correction walk into a dimension nothing downstream can interpret. The Calories row is
  measured in energy, sodium in mass, whatever the panel happened to print.
- **A nutrient the panel does not state stays `.unknown`.** It is shown as "Not on the label" and is
  left out of the product rather than stored as zero, so `ProductDefinition.value(for:)` reads it back
  as unknown. The four states read on screen as "Not on the label" (unknown), "Does not apply"
  (not applicable), "Less than the label reports (mg)" (below the reporting threshold, with the unit
  in parentheses when the label gives one) and the number with its unit (known). The Add details form
  and the Entry screen read the same words. A value the label states but that cannot be scaled to the
  amount entered reads "Can't be worked out for this amount", which is not the same as a value the
  label does not state.
- **The compound rows are shown under a heading of their own, "Also on the label".** They are not
  folded into the Nutrients list: they are not that list's rows, and listing them there would tell the
  user they are nutrients the journal already knows. Each one is shown under the name the label
  printed, is confirmable and correctable exactly like a nutrient row, and a flagged compound blocks
  `canApply` the way a flagged nutrient does. Only one editor is open at a time: opening a nutrient
  row's correction closes a compound's field and the other way round, because there is one keyboard. A
  confirmed compound reaches the product's `nutrients` under its own slug, so it is stored in the
  snapshot beside the fifteen named ones and the journal and the day's totals keep it rather than
  losing it at the form. A correction picks its unit rather than typing it — a compound has no usual
  unit to fall back on — and a unit of another dimension than the one the label printed is refused.
- **A panel with no readable amount is not turned into a product.** `isUnreadable` is true, the screen
  says the panel could not be read, nothing is filled in, and the only thing offered is another look at
  the panel.

The words above are for people. The stored form is unchanged: a row's candidate id, the snapshot
signature and the `label-…` snapshot id are built from `LabelCaptureRow.describe`, which still reads
"not on the panel" and "below reporting threshold mg". Those strings are stored, never shown on screen,
and not reworded, so a saved label product keeps its id.

The product the review screen hands on records `catalogOrigin` as `label_capture` and its basis as
`per serving`, with the serving spelled out when the panel stated a measure (`per serving (240 mL)`) and
as printed when it stated only a household word (`per serving (1 large biscuit)`). The snapshot carries
only the known, answered values.

`AddIntakeViewModel.applyLabelProduct(_:)` then fills the form the way a barcode lookup fills it: the
nutrients and the serving are attached, the product is written as the snapshot on save, and the name is
left for the user, because a panel states nutrients rather than what the food is called. A captured
product is invalidated by exactly the same things a looked-up one is: a later barcode, another capture,
or a later lookup — and a lookup invalidates from the moment it starts, not when its reply arrives, so
Save cannot store a panel the user has already begun to replace on a slow request.

## More than one photo

A Supplement Facts panel on a small bottle is printed in two columns and does not always fit in one
frame: one photo shows the left column, the next the right one and the "Other ingredients" print, and a
single capture misses half the rows. So a panel may be read across several photos and merged into one
draft, and the review screen offers **Add another photo** once there is something to add to.

- **The second photo is merged, not loaded.** `LabelCaptureViewModel.addPhoto(lines:)` parses the new
  lines and merges them into the draft on screen; `load(lines:)` still replaces everything, and is what
  the first photo of a panel uses. The capture sheet's Capture button hands its lines to
  `LabelCaptureViewModel.capture(lines:)`, which picks between the two, so **the same camera and the
  same text recogniser read every photo** of a panel — the second half is not a different flow.
- **The merge rule, row by row.** A row the draft does not have is added, and belongs to the photo that
  read it. A row the draft has with the *same* value is kept, and the second reading raises its
  confidence: a flag the parser raised on the strength of one photo is answered when another photo
  reads the row the same way. The compound rows under "Also on the label" merge the same way, keyed by
  the slug of the name the label printed, so `Zinc 15mg` meets the `Zinc 11mg` of the first photo
  rather than becoming a second row of its own.
- **A row the photos read differently becomes a conflict.** Every reading is kept and nothing is chosen
  silently: the row is marked for review — it counts as one of the pending values, which is what the
  screen's `isPending` means — the screen lists each reading with its own button and reads
  "Conflict: tap to choose", and so **Save stays disabled until it is resolved**. Confirming keeps the
  value on screen, another button takes that photo's reading, and typing an amount resolves it the
  same way. A resolved conflict is an ordinary answered row: the value on screen is the one that is
  kept. A row the user has already confirmed or corrected is never made a conflict by a later photo —
  their answer outranks anything a second reading says.
- **A third photo is kept, not dropped.** A panel can be read several ways rather than two, so a third
  reading joins the row's `candidates` beside the value on screen instead of replacing one or being
  discarded for arriving late, and the photo counts towards `frameCount` because it read the panel. A
  reading that agrees with any reading already kept, including the displayed value, raises that one's
  support rather than becoming a further candidate. Support includes agreeing photos taken before the
  conflict arose. The screen uses the same photo-and-support summary for the displayed reading and the
  alternatives; corroboration never resolves the conflict automatically. Every candidate's button is labelled with the value it keeps,
  since there is no longer a single "other" one.
- **A row only a later photo supplies keeps the name that photo printed.** `Calcium Citrate 200mg` is
  calcium with the printed form as the row's display name, and a row the first photo left unknown has
  no earlier spelling, so the incoming name is copied onto it. A row that already has a name is not
  renamed by a later photo.
- **Panel-wide facts come from whichever photo read them.** The serving size and the
  servings-per-container count are taken from the first photo that read them, and a later photo never
  replaces one already on screen — never a serving the user has confirmed, which is their answer
  rather than a reading at all.
- **What the screen says.** The header reads "From 2 photos" once more than one photo has contributed,
  and a row that is a conflict is called out in the row itself, beside the readings.
- **A photo that read no amount contributes nothing.** A shot that missed the panel leaves the draft
  exactly as it was and does not count towards the number of photos, rather than looking as though it
  had been merged. A photo that repeats rows the draft already has does count: a second reading of a
  row is what can answer the parser's doubt about the first one.
- **Leaving the camera.** **Back to the values** calls `LabelCaptureSession.cancelAddingPhoto()`, which
  clears the held transcript as well as the flag: the recogniser replaces those lines only when it
  recognises something, so a camera reopened for another photo would otherwise still hold what the
  cancelled one saw, and a Capture taken before anything new was read would merge the photo the user
  backed out of. Coming back the same way from a camera failure does the same thing.
- **Opening the camera ends an open correction.** `beginAddingPhoto()` closes whichever editor was open,
  and the review screen clears its typed draft as it goes: the camera is a different screen, so a field
  left standing behind it would return empty, against a row it was never filled in for. What was
  already stated on the draft — a corrected amount, an entered serving size — is kept.
- **A camera failure keeps the reviewed draft.** `LabelCaptureSheetState` records why the camera stopped
  and decides what the failure screen offers. When the failure arrived while another photo was being
  added, the rows the user had already checked are still behind it, so the screen offers **Back to the
  values** alongside Close; offering only Close would throw away a reviewed draft because a camera
  stopped. With no draft behind it, as before the first photo, Close is the only way out.
- **What retake does.** `retake()` clears every frame: the rows, the serving, the conflicts and the
  photo count all go, and the next capture loads a new panel. A retake is a different product, not the
  next photo of this one — that is what Add another photo is for.

One photo behaves exactly as it did before this: the merge only ever runs when the user asks for
another photo, and `frameCount` is 1 for a single capture, so the header says nothing.

## Privacy: no image is stored or sent

Text recognition runs on the device and nothing leaves it:

- **No image is stored, and none is sent anywhere.** The scanner reads text; the camera's frames and
  any crop of one are never written down and never uploaded. `LabelCaptureSession` keeps the
  transcripts of the items the camera currently recognizes, and each frame replaces the last.
- **Nothing goes over the network.** Label capture makes no request. The `catalogOrigin` recorded with
  the entry says where the values came from, and that is a panel the user read on their own device.
- **Only the panel's text enters the app.** What is stored with the entry is the nutrient values and
  the serving, which is what the user chose to record.
- **The camera is used only for this and for the barcode.** The camera usage description says both: the
  camera reads a barcode to fill the field, and reads the text of a Nutrition Facts panel so the values
  can be checked. No new Info.plist key is needed, and recognition runs on the device.

## What is not here yet

- Panels that are not US Nutrition Facts panels: a supplement facts panel, a menu item or a non-US
  label is out of scope for this parser.
- Reading more than one panel in one capture: the sheet reads what is in the frame, and a capture is one
  panel. One panel may be read across several photos and merged — see above — but two different products
  are never in the same draft.
