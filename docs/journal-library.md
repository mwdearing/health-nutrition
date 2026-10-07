# Journal, entry detail and Library

## Screens
- **Journal** lists active entries grouped by the local day of each entry's own time zone, newest first. An entry whose stored time zone is invalid or whose record cannot be read is left out and counted in a visible note; no zone is guessed. Deleted entries are hidden. An entry that states a meal lists it as a secondary line, and it opens in the entry screen.
- **Entry detail** shows the entry's meal when it states one, the current amounts (exact decimal and unit), the revision history and the delivery state per destination. States are words plus an icon, with an accessibility value, so colour is never the only signal. A missing amount shows "unknown", never 0.
- **When** is the entry's time, in a date picker bounded to now: nobody has eaten anything in the future, and a logged time is corrected backwards. The picker is bound to the entry's **stored** time zone, so what it shows and what it writes is the wall clock the entry states rather than the same instant read in the device's zone; a stored identifier that does not resolve falls back to the current zone. Saving goes through the same one `edit` call as an amount, so the correction is a new revision with the previous one kept, the journal then lists the entry under the corrected day, and the History section shows the correction as a revision like any other. A change of time alone is recorded as "Time corrected" unless a reason was written; a written reason is kept as written. A save that changes the amounts **and** the time is an ordinary edit and is recorded as one, since the time was not the only thing that moved. An edit that does not change the time writes no correction at all.
- Each revision keeps the instant it was written with, so a queued revision that is delivered after the entry's time has been corrected still describes the instant it was written for, rather than the corrected one. See [Journal delivery](relay-delivery.md) and [HealthKit writer](healthkit-writer.md).
- **Edit** parses amounts with the fixed POSIX parser (digits and one point, no locale, no sign). Invalid text gives a field error and writes nothing. A valid save makes exactly one `edit` call and a new revision; if the write fails the previous revision stays and an error is shown.
- **Delete** asks for confirmation, then makes one `delete` call. The entry is hidden, delete operations are queued and the history is kept.
- **Library** shows Favorites first, then Recents. Choosing an item adds a new entry now.

## Repeat semantics
Repeat makes one `create` call for a NEW intake: new lowercase UUID, `occurredAt` is now, the current time zone, the same category and meal, the same components (names, amounts, units) and the same product snapshot if there was one. The original entry is not touched.

## Favorites and recents
- **Recents** are derived, not stored: the 20 most recent distinct active entries, distinct by product snapshot id, otherwise by category and component names.
- **Favorites** are stored templates (display name, category, components as exact decimal text plus unit symbol, optional product snapshot id) in their own store file next to the journal file. A favorite is a copy, not a link, so deleting an entry never removes a favorite.

## Entry points
Today has Journal and Library links, its own rows open the same entry screen the Journal opens, and Add intake has "From library". The Library screen also carries the only way in to the Connections and privacy screen, where the journal can be exported as versioned JSON: see [Journal export](journal-export.md). These are navigation callbacks only; the Today and Add view models are unchanged.

## Deferred
Recipes (ingredient lines, yield and per-serving math) are deferred to NC-04b.

## Follow-ups

- The navigation hooks (`onOpenJournal`, `onOpenLibrary`, `onFromLibrary`) are optional closures that no host supplies yet. Connect them when the app shell exists.
- Unknown amount handling: "unknown" is shown only for a NaN amount, an empty component list or a blank name, because `Decimal` cannot otherwise represent a missing amount. Revisit when the model can.
