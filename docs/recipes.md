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

Logging a portion makes one journal intake in category `recipe` with ONE component, named after the
recipe and holding the portion in the yield's own unit: servings for a yield counted in servings, the
yield's unit (converted exactly through the unit registry) for a total yield. So a journal row reads as
the recipe the user chose, not as a list of nutrients, and repeating or favouriting the entry copies
one amount rather than one amount per nutrient.

The intake references a product snapshot with id `recipe:<recipeID>:v<N>`, origin `recipe_calculated`,
catalog version `N` and a label basis that says what the values are per. The snapshot carries the
per-serving nutrient values, so Today resolves a logged recipe from its product the same way it
resolves a barcode-looked-up product, through `SnapshotNutrientFacts`. A nutrient that is unknown for
this version is stored as `.unknown` in the snapshot, never as zero; a known zero stays a zero in the
snapshot and never becomes a component of its own. If no nutrient is known at all, nothing is logged.

Add's recipe picker applies the same rule before opening Details: at least one per-portion
nutrient must be known, including a known zero. Otherwise it shows
"No nutrient value is known, so nothing was logged." Save remains the only write from Details.

Later edits create a new snapshot id, so older entries keep the version they used. The frozen version
itself stays in the recipe store. The export contract carries the snapshot's identity and basis but
not its nutrient values, so an export says which version an entry used rather than restating the
numbers.

## Invalid records

Every stored version row is decoded, not only the newest one of each recipe, so a row that cannot be
read is skipped and counted wherever it sits in a recipe's history. A recipe whose newest version is
damaged stays visible on the newest version that can be read. Reading one such version directly
reports a corrupt record; reading a recipe's versions skips the damaged rows, so one of them never
stops the next version from being saved.

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
potassium and fiber. A nutrient left blank is unknown, never zero.

A value that was stored in another unit of the same kind (protein in milligrams, say) is converted
into the field's unit exactly, so an edit that only touches the title cannot turn 1000 mg into 1000 g.
A value in a unit that cannot be converted at all keeps both its number and its own unit, and the
field says which unit that is.

A value the field cannot show as a number - not applicable, or below a reporting threshold - is carried
through an edit as it is. Those are stated values rather than missing ones, so an edit that leaves the
field alone must not turn one into unknown; typing a number over it replaces it.

The unit an ingredient's per-unit values are stated in is not entered in the editor: an existing value
is carried through an edit unchanged, and the prompt above the nutrient fields names that basis unit
rather than the ingredient's own unit.
