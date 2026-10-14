# Reference intakes: adult RDAs, AIs and upper limits

`ReferenceIntakes` (`ios/NutritionCore/Sources/NutritionDomain/ReferenceIntakes.swift`) holds the published adult
Dietary Reference Intakes for the vitamins and minerals the app tracks. It is a table, not advice: a screen may show
these values beside a day's total so the number has something to be read against, and say which figure it is (RDA, AI
or UL). Nothing in it is personalised beyond the published row a person picks.

## What it covers

- **Adults only**, in the eight published rows: women or men, aged 19 to 30, 31 to 50, 51 to 70, or 71 and over.
  Pregnancy, lactation and anyone under 19 have rows of their own that the table does not carry, and there is no
  merged row for someone who does not give a sex, because the sources publish none.
- **25 nutrients**: vitamins A, B6, B12, C, D, E and K, thiamin, riboflavin, niacin, folate, biotin, pantothenic acid,
  calcium, iron, magnesium, phosphorus, potassium, zinc, chromium, copper, iodine, manganese, molybdenum and selenium.
  The keys are the journal's own (`HealthKitWritePlanner.micronutrientKeys`), and a test pins that every key and unit
  matches the nutrient mapping.
- **Left out**: chloride (no source was checked for it), sodium (its 2,300 mg is a chronic-disease risk reduction
  level, not an upper limit), and water, energy and the macronutrients, which are goals a person sets.

## Units

Every value is in the unit the app counts that nutrient in, so a day's total can be compared without a conversion:
vitamin A in mcg RAE, niacin in mg NE, folate in mcg DFE, vitamin E in mg alpha-tocopherol. Copper is the one figure
restated: the sources give 900 mcg and 10,000 mcg, and the app counts copper in milligrams, so the table holds 0.9 mg and
10 mg.

The folate limit is the one value on another basis. It is published as 1,000 mcg of **folic acid**, not of DFE, and the
table keeps it that way under the `folicAcid` scope. The journal cannot tell the two apart: a current label states folate
in mcg DFE, and an older label, or a value stored under the `folic-acid` key, states plain micrograms of folic acid, and
both are summed as folate. Since 1 mcg of folic acid is 1.667 mcg DFE (folate fact sheet), a DFE amount always states more
micrograms than the folic acid in it, so comparing it with the 1,000 mcg limit can only warn early. Restating the limit as
1,667 mcg DFE instead would let 1,200 mcg of plain folic acid, which is above the limit, read as below it.

A total a label stated in IU (vitamins A, D and E on older labels) is not converted by the table; the conversion depends
on the form, and a caller that cannot convert should not compare.

## Upper limits and what they count

A Tolerable Upper Intake Level is nil where the Food and Nutrition Board set none (vitamins B12 and K, thiamin,
riboflavin, biotin, pantothenic acid, potassium, chromium). Nil means no level was determined, never that any amount is
fine.

Most limits count food, water and supplements together (`allSources`). Five count only some sources or forms, and
comparing a whole day's total against them would read ordinary food as over a limit that was never set for food. Each
source set has its own scope, so a caller can tell which entries a limit counts without a list of nutrient names:

| Nutrient | What the limit counts | `UpperLimitScope` |
|---|---|---|
| Magnesium (350 mg) | Supplements and medicines only, never food or water | `supplementsAndMedicines` |
| Niacin (35 mg) | Supplemental niacin, from supplements and fortified foods | `supplementsAndFortifiedFoods` |
| Vitamin E (1,000 mg) | Any form of supplemental alpha-tocopherol, from supplements and fortified foods | `supplementsAndFortifiedFoods` |
| Folate (1,000 mcg of folic acid) | Synthetic folic acid from supplements and fortified foods, in mcg of folic acid | `folicAcid` |
| Vitamin A (3,000 mcg) | Preformed vitamin A (retinol and its esters) only, from animal foods and supplements | `preformedVitaminA` |

So the magnesium limit sits below the men's allowance, which is coherent only because it counts supplements alone.

## Sources

Every value was read on 2026-10-14 from the NIH Office of Dietary Supplements health-professional fact sheets, which
restate the Food and Nutrition Board's DRI tables (Institute of Medicine 1997 to 2011, National Academies 2019 for
potassium):

| Nutrients | Fact sheet |
|---|---|
| Vitamin A, B6, B12, C, D, E, K | `https://ods.od.nih.gov/factsheets/VitaminA-HealthProfessional/` and the matching `VitaminB6`, `VitaminB12`, `VitaminC`, `VitaminD`, `VitaminE`, `VitaminK` pages |
| Thiamin, riboflavin, niacin, folate, biotin, pantothenic acid | `Thiamin`, `Riboflavin`, `Niacin`, `Folate`, `Biotin`, `PantothenicAcid` pages |
| Calcium, iron, magnesium, phosphorus, potassium, zinc | `Calcium`, `Iron`, `Magnesium`, `Phosphorus`, `Potassium`, `Zinc` pages |
| Chromium, copper, iodine, manganese, molybdenum, selenium | `Chromium`, `Copper`, `Iodine`, `Manganese`, `Molybdenum`, `Selenium` pages |

Each page is `https://ods.od.nih.gov/factsheets/<Name>-HealthProfessional/`. The values are in the RDA or AI table
(Table 1) and the UL table (Table 3, or Table 4 for vitamin D) of each sheet. The scope of each limit comes from the
sheet's own text beside its UL table. `ReferenceIntakesTests` asserts the break points by hand (magnesium at 31; B6,
chromium, calcium and women's iron at 51; vitamin D and the phosphorus limit at 71), so a typo fails a test.

## Who uses it

The vitamins and minerals screen reached from Today compares the day with this table
([vitamins-and-minerals.md](vitamins-and-minerals.md)). Upper-limit warnings in a supplement stack are planned. Wording
follows the app's "no scores, no advice" rule: a value is labelled as a reference value with its kind, and the screen
states a comparison, not a recommendation.
