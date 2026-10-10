# Ingredient density

The recipe editor can fill an ingredient's density (grams per milliliter, the "Weight per mL" field) from a built-in table of typical densities. The table is a suggestion. A density the user types is always kept.

## Source and attribution

- The table comes from the ExactCup Ingredient Density Dataset, licensed under CC BY 4.0 (https://exactcup.github.io/). It lists grams in one US customary cup for 80 ingredients.
- The generated file `ios/NutritionCore/Sources/NutritionDomain/IngredientDensityData.swift` holds the rows. It is generated from the dataset; do not edit it by hand.
- The editor shows the attribution line, `IngredientDensityCatalog.attribution`, while a catalog value is offered or still unchanged in the field. A saved recipe does not remember where a density came from, so the line does not return after reopening. The license requires that credit.

## Conversion

- The table gives grams per cup. The editor's density is grams per milliliter, so the app divides by the US customary cup, exactly 236.5882365 mL, and rounds to six fraction digits.
- `MeasureUnit.cup`, `MeasureUnit.tablespoon` (symbol `tbsp`) and `MeasureUnit.teaspoon` (symbol `tsp`) have exact factors: one cup is 236.5882365 mL, one tablespoon is 1/16 of a cup (14.78676478125 mL) and one teaspoon is 1/3 of a tablespoon (4.92892159375 mL).
- A grams figure from the table is `grams per cup x milliliters / 236.5882365`, computed in one exact multiplication and division and rounded once to six fraction digits. A full cup is therefore exactly its table value.
- These volume units are input and display only. They are not stored units: storage keeps metric mass and volume, and the export and relay never see a cup, tablespoon or teaspoon.

## Add intake behavior

- The Add intake unit picker offers cup, tbsp and tsp. Under the US system they follow `oz` and `fl oz`; under metric they are in the whole registry.
- A volume typed in one of them is converted with the catalog density only when the name matches exactly one row and the entry's label basis is a mass or absent. An entry typed by hand has no basis, so it qualifies. A product whose label is per 100 mL, per serving or unresolved keeps the amount in mL, whatever its name says.
- When the conversion applies, the form shows the line "About <n> g, using a typical density for <catalog name>." with the attribution beneath it. The saved entry stores grams, and the "This adds" preview uses the same grams.
- When a volume is chosen for a food the catalog does not name, or for a name that matches more than one row, the form shows "No typical density is known for this food, so it is saved in mL." The amount is stored in milliliters.
- Ounces keep their existing behavior: they convert to grams or milliliters by exact factor and never use a density.

## Matching

- A name matches a catalog row when, after trimming, lowercasing, reading hyphens as spaces and collapsing runs of spaces, it equals the row's name, slug or one of its aliases.
- Matching is exact. There is no substring or fuzzy match, so "flour" and "purpose flour" match nothing.
- A name that matches more than one row gives no suggestion. "Walnuts", "pecans" and "caster sugar" each belong to two rows, so the app does not guess which one the user means.
- An unknown name gives no suggestion, and the density field stays blank.

## Editor behavior

- The suggestion appears under the density field only when that field is blank and the ingredient name matches one row. It shows the catalog name, the grams per cup and a "Use it" button.
- "Use it" fills the field with the grams per milliliter. The attribution line stays while the field still holds the catalog value. Typing over the value turns the line off.
- A density the user has typed is never replaced by the suggestion.

## Accuracy

The values are typical figures per cup. Real densities vary with brand, moisture, how the ingredient is packed and how it is measured. A suggestion is a starting point to check, not a measurement.

## Out of scope

- The catalog does not change the recipe schema, the export or the relay contract.
- No nutrient values come from the table. It only supplies the mass per volume used to convert between weight and volume.
