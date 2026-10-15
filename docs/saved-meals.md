# Saved meals

A saved meal is a named group of foods logged together, such as "Usual breakfast". It is the M1 "saved meals" item of the parity roadmap.

**Screens.** A meal is saved from the Journal with **Save as meal** on any meal title, and logged from Add's **Find products** screen, which lists saved meals under All kinds, asks which meal to log one under and offers Undo. Swiping a saved meal there removes it. [Journal, entry detail, Library, favorites and repeat](journal-library.md) describes both screens. `SavedMealsModel` (`SavedMealsModel.swift`) is the model they share.

## What a saved meal holds

- `SavedMeal` (`ios/NutritionCore/Sources/NutritionUI/SavedMeals.swift`): an id, a name, the meal it was saved under (Breakfast, Lunch, Dinner, Snack or none) and its items. Logging takes the meal it is given, so a screen offers the saved one first and asks.
- Each item is a `FavoriteTemplate`, the shape a favorite has: the title, the category, the components with their amounts as exact decimal text and their unit symbols, and the product snapshot id when the item came from a product. Like a favorite, a saved meal is a copy of what was eaten and not a link to entries, so editing or deleting an entry never changes it. An item states no meal of its own; the group's meal applies to all of its items.

## Saving

`SavedMealBook` adds, renames and removes saved meals, newest first. It refuses, and writes nothing, when:

| Refusal | When |
| --- | --- |
| `emptyName` | The name is empty once outer spaces are trimmed. |
| `nameTooLong` | The trimmed name is over 60 characters. |
| `duplicateName` | Another saved meal has the same name, ignoring case and outer spaces. A meal may be renamed to its own name in another case. |
| `itemCount` | There are no items, or more than 30. |
| `tooManyMeals` | There are already 100 saved meals. |
| `unsavableAmount` | An item has no components, an unknown amount, or an amount that does not read back as the same number in the app's decimal format (a zero amount is one), so a saved meal logs exactly what was eaten. This is stricter than a favorite, which only needs the text to parse. |
| `notFound` | A rename or removal names a meal that is no longer there. |
| `unreadable` | A stored value exists but is not a list this build can read. It is reported, never read as an empty list, and nothing is saved over it. |

Each change reads the list, edits it and writes it back as one step under the store's lock, so two changes made at once through one store cannot drop one another. The app keeps one store.

## Where it is kept

The list is kept on this phone only, as JSON in the app's defaults domain under the key `library.savedMeals.v1` (`UserDefaultsSavedMealStore`). The list itself is never sent anywhere. Erase all data removes the key through the store's `eraseAll()`, then reads the list again (see [Erase all data](erase-all-data.md)). The model reads the list again whenever Find products appears, so a list changed in another window is not shown stale; a notice belongs to the action that set it and is dropped with the next read.

**Export and restore.** From journal export version 4, a backup carries the saved meals in the list's order, with the products their items use, and a restore brings them back into an empty list, in the same second phase as the favorites (see [Journal export](journal-export.md)). A restore writes the list and then a receipt naming the file (`library.savedMeals.restoreReceipt.v1`), which Erase all data also removes. The limits above are shared with the importer (`JournalSavedMealLimits`), so a restore cannot write a list the app would refuse to save.

## Logging

`SavedMealLogger.log(_:as:now:)` logs every item as its own ordinary entry: one `create` per item, all at the same time, under the meal picked (or none), in the order the items were saved. Each entry is like any other entry, so once Apple Health is connected it is written there as usual (see [HealthKit writer](healthkit-writer.md)).

- **An item that cannot be logged as it was saved is skipped and counted, and the rest are logged.** That is an item with no components, an amount or unit symbol that no longer reads back (a negative or zero amount among them), or a saved product that is no longer in the journal. Damaged stored data that reads back but that the journal itself refuses when the entry is written (such as an invalid component id) is a failed write, below. The result, `SavedMealLogResult`, lists the entries created and how many items were skipped, so a screen can say what happened.
- **A failed write leaves no entry behind.** Any other store failure deletes the entries that call already created before the error is passed on, so a meal is never left half logged. Those deletes go through the journal's usual delete, so like any deleted entry they are kept as hidden history and retracted from Apple Health if a delivery already ran. If one of those deletes fails as well, the error is a `SavedMealPartialLogError` that names the entries still in the journal, so a screen can offer to remove them.
- **Undo** (`undo(_:now:)`) deletes exactly the entries the result lists. An entry already deleted counts as undone. When another delete fails, every remaining entry is still tried, and the ones left are reported as `SavedMealUndoError.incomplete(remainingIDs:)`.

Tests: `ios/NutritionCore/Tests/NutritionUITests/SavedMealsTests.swift` (the store, book and logger) and `SavedMealsModelTests.swift` (the screens' model and Save as meal from the Journal).

## Shortcut

**Log a saved meal** is a Siri, Spotlight and Shortcuts action (`LogSavedMealIntent`, next to Log water). It asks for a saved meal and, optionally, a meal; with none it uses the meal the saved meal was saved with. It opens the app and logs every item through the app's own journal store, as the screen does, then reloads the app's screens and runs one Apple Health delivery pass, as an add from the app does, and says what it did: "Added Usual breakfast to today's diary.", how many items were skipped, that nothing could be added, or "You have no saved meals yet. Save one from a meal in the Diary." It offers no Undo; the entries can be deleted in the Diary like any other. Entries left by a failed write that could not be removed are reported to the app's saved meals warning. The list of saved meals it offers is read straight from the store. Logging needs an unlocked phone (`requiresLocalDeviceAuthentication`); picking the saved meal can happen before that, so their names can show on a locked phone through Siri. The app hands its shortcuts to the system at every launch.
