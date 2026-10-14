# Saved meals

A saved meal is a named group of foods logged together, such as "Usual breakfast". It is the M1 "saved meals" item of the parity roadmap.

**State.** This is the model, storage and logging only. No screen shows saved meals yet: saving a meal from the Journal and logging one from Add come with the wiring change, which also adds the store to Erase all data. Until then the app never writes the stored list.

## What a saved meal holds

- `SavedMeal` (`ios/NutritionCore/Sources/NutritionUI/SavedMeals.swift`): an id, a name, the meal it is logged under by default (Breakfast, Lunch, Dinner, Snack or none) and its items.
- Each item is a `FavoriteTemplate`, the shape a favorite has: the title, the category, the components with their amounts as exact decimal text and their unit symbols, and the product snapshot id when the item came from a product. Like a favorite, a saved meal is a copy of what was eaten and not a link to entries, so editing or deleting an entry never changes it. An item states no meal of its own; the group's meal applies to all of its items.

## Saving

`SavedMealBook` adds, renames and removes saved meals, newest first. It refuses, and writes nothing, when:

| Refusal | When |
| --- | --- |
| `emptyName` | The name is empty once outer spaces are trimmed. |
| `nameTooLong` | The trimmed name is over 60 characters. |
| `duplicateName` | Another saved meal has the same name, ignoring case and outer spaces. A meal may be renamed to its own name in another case. |
| `itemCount` | There are no items, or more than 30. |
| `unsavableAmount` | An item has no components, an unknown amount, or an amount that does not read back as the same number in the app's decimal format (a zero amount is one). This is the rule favorites follow, so a saved meal logs exactly what was eaten. |
| `notFound` | A rename or removal names a meal that is no longer there. |
| `unreadable` | The stored list exists but cannot be read. It is reported, never read as an empty list, and nothing is saved over it. |

## Where it is kept

The list is kept on this phone only, as JSON in the app's defaults domain under the key `library.savedMeals.v1` (`UserDefaultsSavedMealStore`). Nothing about it is sent anywhere. The store's `eraseAll()` removes the key; it joins Erase all data with the wiring change.

**Known gap: export and restore.** The journal export does not carry saved meals, and restoring an export does not bring them back. Favorites are exported; saved meals are not, until the export format takes them in a later version.

## Logging

`SavedMealLogger.log(_:as:now:)` logs every item as its own ordinary entry: one `create` per item, all at the same time, under the meal picked (or none), in the order the items were saved. Each entry is like any other entry, so once Apple Health is connected it is written there as usual (see [HealthKit writer](healthkit-writer.md)).

- **An item that cannot be logged as it was saved is skipped and counted, and the rest are logged.** That is an item whose amounts no longer read back, or whose saved product is no longer in the journal. The result, `SavedMealLogResult`, lists the entries created and how many items were skipped, so a screen can say what happened.
- **A failed write logs nothing.** Any other store failure deletes the entries that call already created before the error is passed on, so a meal is never left half logged.
- **Undo** (`undo(_:now:)`) deletes exactly the entries the result lists. An entry already deleted counts as undone. When another delete fails, every remaining entry is still tried, and the ones left are reported as `SavedMealUndoError.incomplete(remainingIDs:)`.

Tests: `ios/NutritionCore/Tests/NutritionUITests/SavedMealsTests.swift`.
