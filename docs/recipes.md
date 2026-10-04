# Recipes

Personal recipes: you enter ingredients and a yield, the app calculates nutrient values per serving or per portion, and you can log a portion into the journal.

## Model

- A recipe has numbered, immutable versions. Each version holds a title, notes, ingredient lines and a yield.
- An ingredient has a quantity (exact decimal amount and a unit from the unit registry) and nutrient values stated per ONE of a basis unit (by default the ingredient's own unit). An optional density (g per mL) is used only to convert between mass and volume.
- The yield is either a number of servings or a total quantity such as 800 g.
- Validation: non-empty title, at least one ingredient, yield greater than zero, ingredient quantities greater than zero, unique ingredient ids.

## Math

- All arithmetic is `Decimal`; text is parsed and written in the POSIX format ("1.5", never "1,5").
- An ingredient's contribution is its quantity, converted exactly to the basis unit, times the per-unit value. Conversion goes through the unit registry only.
- Unknown is never zero. If an ingredient's value is unknown, not applicable, below a reporting threshold, missing, or cannot be converted (for example mass to volume without a density), the ingredient lacks that nutrient, the recipe total for it is unknown, and a lacking count is kept. A known zero stays zero.
- No cooking or retention factors are applied.
- Per portion: for servings, the total is multiplied by portion / servings; for a total yield, the portion is an amount converted to the yield's unit, and the factor is portion / yield. A portion of zero or less is rejected. Unknown stays unknown.
- Coverage reads "N of M ingredients lack <nutrient>".

## Versioning

Saving always writes the next version number (1 for a new recipe, else latest plus one) and never overwrites a version. Editing a recipe saves a new version; earlier versions stay readable.

## Logging and provenance

Logging a portion makes one journal intake in category `recipe`, with one component per nutrient whose per-portion value is known. Unknown nutrients are omitted, never written as zero. If no nutrient is known, nothing is logged.

The intake references a product snapshot with id `recipe:<recipeID>:v<N>`, origin `recipe_calculated` and catalog version `N`. Later edits create a new snapshot id, so older entries keep the version they used. The frozen version itself stays in the recipe store.

## Invalid records

Stored recipe rows that cannot be decoded or fail validation are skipped when listing and counted; the list screen says how many could not be read. Reading one such version directly reports a corrupt record.

## Deleting

Deleting a recipe hides it from the list. Every stored version is kept.

## Privacy

Recipes are personal. They are stored on the device in their own store file (`recipes.store`, next to
the journal and favorites files), and are never shared, synced or published.

## Where the screens live

The app creates one `SwiftDataRecipeStore` at startup and opens the recipe list from a row in
Library. The list, detail and editor screens share one navigation stack, so a recipe opens over the
list and editing pushes a new version over the detail. A failed open of any store file closes the
files already opened and names the one that failed on the startup failure screen.

## What the editor can change

The editor asks for every nutrient the Today screen tracks by default: energy, protein, sodium,
potassium and fiber. A nutrient left blank is unknown, never zero. The unit an ingredient's
per-unit values are stated in is not entered in the editor: an existing value is carried through an
edit unchanged, so a recipe stated per 100 g stays stated per 100 g.
