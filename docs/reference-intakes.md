# Reference intakes: adult RDAs, AIs and upper limits

`ReferenceIntakes` (`ios/NutritionCore/Sources/NutritionDomain/ReferenceIntakes.swift`) holds the published adult
Dietary Reference Intakes for the vitamins and minerals the app tracks. It is a table, not advice: a screen may show
these values beside a day's total so the number has something to be read against, and say which figure it is (RDA, AI
or UL). Nothing in it is personalised beyond the published row a person picks.

## What it covers

- **Adults only** in the code (the 14 to 18 rows and the FDA Daily Values are documented below as data), in twelve published rows: women or men aged 19 to 30, 31 to 50, 51 to 70, or 71 and over, plus
  pregnancy and breastfeeding (lactation) for ages 19 to 30 and 31 to 50 ("Pregnancy 19 to 30", "Breastfeeding 31 to
  50"). Pregnancy and breastfeeding use the Pregnancy and Lactation columns of the same fact sheet tables; their upper
  limits are the adult ones for the band, except phosphorus in pregnancy (3,500 mg instead of 4,000), the one limit
  those tables set differently. Anyone under 19 has rows of their own that the table does not carry, and there is no
  merged row for someone who does not give a sex, because the sources publish none. `ReferenceGroup(lifeStage:ageBand:)`
  returns nil for a band the tables do not publish (pregnancy over 50), and a decoded group is held to the same rule.
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

A vitamin D amount a label stated in IU is restated in mcg before it is totalled (an IU of vitamin D is defined as
0.025 mcg, so 400 IU is 10 mcg), so it compares with the vitamin D values here. A vitamin A or E amount stated in IU
is not converted: the factor depends on the form, and a caller that cannot convert should not compare.

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
(Table 1, or Table 2 for vitamin D) and the UL table (Table 3, or Table 4 for vitamin D) of each sheet. The scope of each limit comes from the
sheet's own text beside its UL table. `ReferenceIntakesTests` asserts the break points by hand (magnesium at 31; B6,
chromium, calcium and women's iron at 51; vitamin D and the phosphorus limit at 71), so a typo fails a test.

### Table per nutrient

The table each adult value comes from. Re-checked on 2026-10-27: every adult value in `ReferenceIntakes.swift` (the
RDA or AI for women and men in each band, pregnancy and lactation for 19 to 50, and the UL for each band, 368 values)
matches the fact sheet table below.

| Nutrient | Fact sheet | Intake table | Upper limit table |
|---|---|---|---|
| Vitamin A | https://ods.od.nih.gov/factsheets/VitaminA-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Vitamin A | Table 3: Tolerable Upper Intake Levels (ULs) for Preformed Vitamin A |
| Vitamin B6 | https://ods.od.nih.gov/factsheets/VitaminB6-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Vitamin B6 | Table 3: Tolerable Upper Intake Levels (ULs) for Vitamin B6 |
| Vitamin B12 | https://ods.od.nih.gov/factsheets/VitaminB12-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Vitamin B12 in Micrograms (mcg) | none (no UL set) |
| Vitamin C | https://ods.od.nih.gov/factsheets/VitaminC-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Vitamin C in Milligrams (mg) | Table 3: Tolerable Upper Intake Levels (ULs) for Vitamin C in Milligrams (mg) |
| Vitamin D | https://ods.od.nih.gov/factsheets/VitaminD-HealthProfessional/ | Table 2: Recommended Dietary Allowances (RDAs) for Vitamin D in Micrograms (mcg) and International Units (IU) | Table 4: Tolerable Upper Intake Levels (ULs) for Vitamin D in Micrograms (mcg) and International Units (IU) |
| Vitamin E | https://ods.od.nih.gov/factsheets/VitaminE-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Vitamin E (Alpha-Tocopherol) in Milligrams (mg) | Table 3: Tolerable Upper Intake Levels (ULs) for Vitamin E in Milligrams (mg) |
| Vitamin K | https://ods.od.nih.gov/factsheets/VitaminK-HealthProfessional/ | Table 1: Adequate Intakes (AIs) for Vitamin K in Micrograms (mcg) | none (no UL set) |
| Thiamin | https://ods.od.nih.gov/factsheets/Thiamin-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Thiamin | none (no UL set) |
| Riboflavin | https://ods.od.nih.gov/factsheets/Riboflavin-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Riboflavin | none (no UL set) |
| Niacin | https://ods.od.nih.gov/factsheets/Niacin-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Niacin | Table 3: Tolerable Upper Intake Levels (ULs) for Niacin |
| Folate | https://ods.od.nih.gov/factsheets/Folate-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Folate | Table 3: Tolerable Upper Intake Levels (ULs) for Folate from Supplements or Fortified Foods |
| Biotin | https://ods.od.nih.gov/factsheets/Biotin-HealthProfessional/ | Table 1: Adequate Intakes (AIs) for Biotin | none (no UL set) |
| Pantothenic acid | https://ods.od.nih.gov/factsheets/PantothenicAcid-HealthProfessional/ | Table 1: Adequate Intakes (AIs) for Pantothenic Acid | none (no UL set) |
| Calcium | https://ods.od.nih.gov/factsheets/Calcium-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Calcium in Milligrams (mg) | Table 3: Tolerable Upper Intake Levels (ULs) for Calcium in Milligrams (mg) |
| Iron | https://ods.od.nih.gov/factsheets/Iron-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Iron in Milligrams (mg) | Table 3: Tolerable Upper Intake Levels (ULs) for Iron |
| Magnesium | https://ods.od.nih.gov/factsheets/Magnesium-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Magnesium in Milligrams (mg) | Table 3: Tolerable Upper Intake Levels (ULs) for Supplemental Magnesium in Milligrams (mg) |
| Phosphorus | https://ods.od.nih.gov/factsheets/Phosphorus-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Phosphorus | Table 3: Tolerable Upper Intake Levels (ULs) for Phosphorus |
| Potassium | https://ods.od.nih.gov/factsheets/Potassium-HealthProfessional/ | Table 1: Adequate Intakes (AIs) for Potassium | none (no UL set) |
| Zinc | https://ods.od.nih.gov/factsheets/Zinc-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Zinc in Milligrams (mg) | Table 3: Tolerable Upper Intake Levels (ULs) for Zinc in Milligrams (mg) |
| Chromium | https://ods.od.nih.gov/factsheets/Chromium-HealthProfessional/ | Table 1: Adequate Intakes (AIs) for Chromium | none (no UL set) |
| Copper | https://ods.od.nih.gov/factsheets/Copper-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Copper | Table 3: Tolerable Upper Intake Levels (ULs) for Copper |
| Iodine | https://ods.od.nih.gov/factsheets/Iodine-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Iodine | Table 3: Tolerable Upper Intake Levels (ULs) for Iodine |
| Manganese | https://ods.od.nih.gov/factsheets/Manganese-HealthProfessional/ | Table 1: Adequate Intakes (AIs) for Manganese | Table 3: Tolerable Upper Intake Levels (ULs) for Manganese |
| Molybdenum | https://ods.od.nih.gov/factsheets/Molybdenum-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Molybdenum | Table 3: Tolerable Upper Intake Levels (ULs) for Molybdenum |
| Selenium | https://ods.od.nih.gov/factsheets/Selenium-HealthProfessional/ | Table 1: Recommended Dietary Allowances (RDAs) for Selenium in Micrograms (mcg) | Table 3: Tolerable Upper Intake Levels (ULs) for Selenium in Micrograms (mcg) |

## Ages 14 to 18 (reference data only, not in the code)

Goal setup accepts ages 18 to 100 (`GoalEstimator.minimumAge` is 18), so an 18-year-old can set goals, but
`ReferenceAgeBand(ageYears:)` returns nil under 19 and the app shows no reference value for them. These are the published
14 to 18 rows, read on 2026-10-27 from the same fact sheet tables, for when the code gains the band. Ages 14 to 17 can't
reach goal setup today. The UL scopes are the adult ones (magnesium counts supplements only, and so on); the
upper-limit column applies to all four columns unless it says otherwise.

| Nutrient | Kind | Male | Female | Pregnancy | Lactation | UL (all four) | Fact sheet tables |
|---|---|---|---|---|---|---|---|
| Vitamin A | RDA | 900 mcg RAE | 700 mcg RAE | 750 mcg RAE | 1,200 mcg RAE | 2,800 mcg | Table 1; Table 3 |
| Vitamin B6 | RDA | 1.3 mg | 1.2 mg | 1.9 mg | 2.0 mg | 80 mg | Table 1; Table 3 |
| Vitamin B12 | RDA | 2.4 mcg | 2.4 mcg | 2.6 mcg | 2.8 mcg | none set | Table 1; none (no UL set) |
| Vitamin C | RDA | 75 mg | 65 mg | 80 mg | 115 mg | 1,800 mg | Table 1; Table 3 |
| Vitamin D | RDA | 15 mcg (600 IU) | 15 mcg (600 IU) | 15 mcg (600 IU) | 15 mcg (600 IU) | 100 mcg (4,000 IU) | Table 2; Table 4 |
| Vitamin E | RDA | 15 mg | 15 mg | 15 mg | 19 mg | 800 mg | Table 1; Table 3 |
| Vitamin K | AI | 75 mcg | 75 mcg | 75 mcg | 75 mcg | none set | Table 1; none (no UL set) |
| Thiamin | RDA | 1.2 mg | 1.0 mg | 1.4 mg | 1.4 mg | none set | Table 1; none (no UL set) |
| Riboflavin | RDA | 1.3 mg | 1.0 mg | 1.4 mg | 1.6 mg | none set | Table 1; none (no UL set) |
| Niacin | RDA | 16 mg NE | 14 mg NE | 18 mg NE | 17 mg NE | 30 mg | Table 1; Table 3 |
| Folate | RDA | 400 mcg DFE | 400 mcg DFE | 600 mcg DFE | 500 mcg DFE | 800 mcg | Table 1; Table 3 |
| Biotin | AI | 25 mcg | 25 mcg | 30 mcg | 35 mcg | none set | Table 1; none (no UL set) |
| Pantothenic acid | AI | 5 mg | 5 mg | 6 mg | 7 mg | none set | Table 1; none (no UL set) |
| Calcium | RDA | 1,300 mg | 1,300 mg | 1,300 mg | 1,300 mg | 3,000 mg | Table 1; Table 3 |
| Iron | RDA | 11 mg | 15 mg | 27 mg | 10 mg | 45 mg | Table 1; Table 3 |
| Magnesium | RDA | 410 mg | 360 mg | 400 mg | 360 mg | 350 mg | Table 1; Table 3 |
| Phosphorus | RDA | 1,250 mg | 1,250 mg | 1,250 mg | 1,250 mg | 4,000 mg (3,500 mg in pregnancy) | Table 1; Table 3 |
| Potassium | AI | 3,000 mg | 2,300 mg | 2,600 mg | 2,500 mg | none set | Table 1; none (no UL set) |
| Zinc | RDA | 11 mg | 9 mg | 12 mg | 13 mg | 34 mg | Table 1; Table 3 |
| Chromium | AI | 35 mcg | 24 mcg | 29 mcg | 44 mcg | none set | Table 1; none (no UL set) |
| Copper | RDA | 890 mcg | 890 mcg | 1,000 mcg | 1,300 mcg | 8,000 mcg | Table 1; Table 3 |
| Iodine | RDA | 150 mcg | 150 mcg | 220 mcg | 290 mcg | 900 mcg | Table 1; Table 3 |
| Manganese | AI | 2.2 mg | 1.6 mg | 2.0 mg | 2.6 mg | 9 mg | Table 1; Table 3 |
| Molybdenum | RDA | 43 mcg | 43 mcg | 50 mcg | 50 mcg | 1,700 mcg | Table 1; Table 3 |
| Selenium | RDA | 55 mcg | 55 mcg | 60 mcg | 70 mcg | 400 mcg | Table 1; Table 3 |

Copper is listed in mcg as the sheets give it; the app would hold 0.89 mg, 1.0 mg and 1.3 mg, and a UL of 8 mg.

## FDA Daily Values (21 CFR 101.9)

The Daily Values are the label reference amounts behind "% Daily Value". They are not age or sex specific: one column
covers adults and children 4 years and older, and a separate column covers pregnancy and lactation. They are useful as
the "use FDA recommendations" default for someone who doesn't give an age or sex; the DRIs above are the age and sex
specific values. Read on 2026-10-27 from the eCFR,
`https://www.ecfr.gov/current/title-21/chapter-I/subchapter-B/part-101/subpart-A/section-101.9`, which states "up to date
as of 10/26/2026" and "last amended 10/21/2026".

### Vitamins and minerals: Reference Daily Intakes, 21 CFR 101.9(c)(8)(iv)

| Nutrient | App key | Adults and children 4+ | Pregnancy and lactation |
|---|---|---|---|
| Vitamin D | `vitaminD` | 20 mcg | 15 mcg |
| Calcium | `calcium` | 1,300 mg | 1,300 mg |
| Iron | `iron` | 18 mg | 27 mg |
| Potassium | `potassium` | 4,700 mg | 5,100 mg |
| Vitamin A | `vitaminA` | 900 mcg RAE | 1,300 mcg RAE |
| Vitamin C | `vitaminC` | 90 mg | 120 mg |
| Vitamin E | `vitaminE` | 15 mg (alpha-tocopherol) | 19 mg |
| Vitamin K | `vitaminK` | 120 mcg | 90 mcg |
| Thiamin | `thiamin` | 1.2 mg | 1.4 mg |
| Riboflavin | `riboflavin` | 1.3 mg | 1.6 mg |
| Niacin | `niacin` | 16 mg NE | 18 mg NE |
| Vitamin B6 | `vitaminB6` | 1.7 mg | 2.0 mg |
| Folate | `folate` | 400 mcg DFE | 600 mcg DFE |
| Vitamin B12 | `vitaminB12` | 2.4 mcg | 2.8 mcg |
| Biotin | `biotin` | 30 mcg | 35 mcg |
| Pantothenic acid | `pantothenicAcid` | 5 mg | 7 mg |
| Phosphorus | `phosphorus` | 1,250 mg | 1,250 mg |
| Iodine | `iodine` | 150 mcg | 290 mcg |
| Magnesium | `magnesium` | 420 mg | 400 mg |
| Zinc | `zinc` | 11 mg | 13 mg |
| Selenium | `selenium` | 55 mcg | 70 mcg |
| Copper | `copper` | 0.9 mg | 1.3 mg |
| Manganese | `manganese` | 2.3 mg | 2.6 mg |
| Chromium | `chromium` | 35 mcg | 45 mcg |
| Molybdenum | `molybdenum` | 45 mcg | 50 mcg |
| Chloride | `chloride` | 2,300 mg | 2,300 mg |
| Choline | none (a label row the scanner reads, not a stored key) | 550 mg | 550 mg |

The section also sets an infants column and a children 1 to 3 column, which the app has no use for and which are left
out here. Vitamin D may be stated in IU in parentheses after the mcg amount; folate is in mcg DFE (1 DFE = 1 mcg food
folate = 0.6 mcg folic acid); 1 mg alpha-tocopherol = 2 mg all-rac-alpha-tocopherol.

### Macronutrients and other components: Daily Reference Values, 21 CFR 101.9(c)(9) and (c)(7)(iii)

| Component | Product panel key | Adults and children 4+ | Pregnancy and lactation | Basis |
|---|---|---|---|---|
| Fat | `fat` | 78 g | 78 g | 2,000 Calories |
| Saturated fat | `saturatedFat` | 20 g | 20 g | 2,000 Calories |
| Cholesterol | `cholesterol` | 300 mg | 300 mg | fixed |
| Total carbohydrate | `carbohydrates` | 275 g | 275 g | 2,000 Calories |
| Sodium | `sodium` | 2,300 mg | 2,300 mg | fixed |
| Dietary fiber | `fiber` | 28 g | 28 g | 2,000 Calories |
| Protein | `protein` | 50 g | 71 g | 2,000 Calories; pregnancy and lactation from (c)(7)(iii) |
| Added sugars | `addedSugars` | 50 g | 50 g | 2,000 Calories |

The keys are the product panel's (`CustomProductValidation.standardDimensions`); the journal and the Apple Health writer
name two of them differently, `carbohydrate` and `sugar`. Saturated fat, cholesterol and added sugars are stored on
products but not written to Apple Health. The "2,000 Calories" rows are set for a reference intake of 2,000 Calories
(the table's footnote 1). There is no Daily Value for energy itself, total sugars (`sugars`), trans fat (`transFat`),
water or caffeine: those keys have no FDA default. The protein DRV of 50 g is what a label's %DV uses for adults; the 71 g figure is the RDI the section sets for
pregnancy and lactation.

## Not verified

These values were not checked against a primary source and are not in the tables above:

- **Chloride by age and sex (DRI).** There is no ODS fact sheet for chloride, and the National Academies summary tables
  on NCBI Bookshelf (`NBK545442`, `NBK56068`) answered with a bot check when fetched on 2026-10-27. The FDA Daily Value
  for chloride (2,300 mg) is verified above.
- **Sodium, fiber, protein, carbohydrate, fat and water by age and sex (DRIs and AMDRs).** Same source, same block. The
  FDA Daily Values for these are verified above.
- **Choline** is not tracked by the app; its ODS tables were read (AI 550 mg men, 425 mg women, 14 to 18: 550 mg and
  400 mg) but are not listed above.

## Who uses it

The vitamins and minerals screen reached from Today compares the day with this table
([vitamins-and-minerals.md](vitamins-and-minerals.md)). Upper-limit warnings in a supplement stack are planned. Wording
follows the app's "no scores, no advice" rule: a value is labelled as a reference value with its kind, and the screen
states a comparison, not a recommendation.
