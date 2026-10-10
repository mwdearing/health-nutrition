# Ingredient density

The recipe editor can fill an ingredient's density (grams per milliliter, the "Weight per mL" field) from a built-in table of typical densities. The table is a suggestion. A density the user types is always kept.

## Source and attribution

- The table comes from the ExactCup Ingredient Density Dataset, licensed under CC BY 4.0 (https://exactcup.github.io/). It lists grams in one US customary cup for 80 ingredients.
- The generated file `ios/NutritionCore/Sources/NutritionDomain/IngredientDensityData.swift` holds the rows. It is generated from the dataset; do not edit it by hand.
- The app shows the attribution line, `IngredientDensityCatalog.attribution`, wherever a catalog value is offered or applied. The license requires that credit.

## Conversion

- The table gives grams per cup. The editor's density is grams per milliliter, so the app divides by the US customary cup, exactly 236.5882365 mL, and rounds to six fraction digits.
- Typed volume units are converted to milliliters at entry with exact factors: one cup is 236.5882365 mL, one tablespoon is 1/16 of a cup (14.78676478125 mL) and one teaspoon is 1/3 of a tablespoon (4.92892159375 mL).
- These volume units are input only. They are not stored units: storage keeps metric mass and volume, and the export and relay never see a cup, tablespoon or teaspoon.

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

- Add intake screens do not use the catalog yet. That is left for a follow-up.
- The catalog does not change the recipe schema, the export or the relay contract.
- No nutrient values come from the table. It only supplies the mass per volume used to convert between weight and volume.
