# Journal, entry detail and Library

## Screens
- **Journal** lists active entries grouped by the local day of each entry's own time zone, newest first. An entry whose stored time zone is invalid or whose record cannot be read is left out and counted in a visible note; no zone is guessed. Deleted entries are hidden.
- **Entry detail** shows the current amounts (exact decimal and unit), the revision history and the delivery state per destination. States are words plus an icon, with an accessibility value, so colour is never the only signal. A missing amount shows "unknown", never 0.
- **Edit** parses amounts with the fixed POSIX parser (digits and one point, no locale, no sign). Invalid text gives a field error and writes nothing. A valid save makes exactly one `edit` call and a new revision; if the write fails the previous revision stays and an error is shown.
- **Delete** asks for confirmation, then makes one `delete` call. The entry is hidden, delete operations are queued and the history is kept.
- **Library** shows Favorites first, then Recents. Choosing an item adds a new entry now.

## Repeat semantics
Repeat makes one `create` call for a NEW intake: new lowercase UUID, `occurredAt` is now, the current time zone, the same category and meal, the same components (names, amounts, units) and the same product snapshot if there was one. The original entry is not touched.

## Favorites and recents
- **Recents** are derived, not stored: the 20 most recent distinct active entries, distinct by product snapshot id, otherwise by category and component names.
- **Favorites** are stored templates (display name, category, components as exact decimal text plus unit symbol, optional product snapshot id) in their own store file next to the journal file. A favorite is a copy, not a link, so deleting an entry never removes a favorite.

## Entry points
Today has Journal and Library links, and Add intake has "From library". These are navigation callbacks only; the Today and Add view models are unchanged.

## Deferred
Recipes (ingredient lines, yield and per-serving math) are deferred to NC-04b.

## Follow-ups

- The navigation hooks (`onOpenJournal`, `onOpenLibrary`, `onFromLibrary`) are optional closures that no host supplies yet. Connect them when the app shell exists.
- Unknown amount handling: "unknown" is shown only for a NaN amount, an empty component list or a blank name, because `Decimal` cannot otherwise represent a missing amount. Revisit when the model can.
