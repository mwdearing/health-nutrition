# Erase all data

Status: Current. Reviewed whenever a store is added or a connection starts writing anywhere.

The Connections and privacy screen has an **Erase all data** action. It removes everything this app
stores on the device, after a confirmation that says what goes and that it cannot be undone. Nothing
is sent anywhere by the erase itself, and no other app on the device is touched.

Code: `ios/NutritionCore/Sources/NutritionJournal/JournalErase.swift` holds the
`JournalErasing` protocol; the screen runs the injected stores in
`ConnectionsPrivacyViewModel.eraseAllData()`.

## What is erased

Three store files, each under Application Support. Each store deletes its own rows in one save, so a
failure leaves that file as it was rather than half emptied.

| File | Store | What goes |
| --- | --- | --- |
| `journal.store` | `SwiftDataJournalStore` | every intake entry, every revision of every entry, every product snapshot, every projection and every queued outbox operation. Deleted entries leave no tombstone either: a tombstone only exists so a later export can retract the entry. |
| `favorites.store` | `SwiftDataFavoritesStore` | every favorite template. A favorite is a copy of an entry's amounts, so it is personal data of the same kind. |
| `recipes.store` | `SwiftDataRecipeStore` | every recipe version and every tombstone of a recipe that was deleted. |

Plus, on the screen that offers the action:

- The exported JSON file the screen was holding, if any. It is a copy of the same history, so it is
  deleted rather than left in the temporary directory. See [journal export](journal-export.md).
- The screen's own state: the entry count goes back to zero and the export is no longer offered.

The stores stay open afterwards. The app carries on with an empty journal, and a new entry, favorite
or recipe can be written straight away. If one store cannot erase, the others still run and the screen
says so, because being told the erase worked when it did not would be the worse failure.

An exported file the person already shared out of the app is a copy the app no longer has a handle
on. The erase cannot reach it; that is what sharing it in the first place meant.

## What is not erased, and why

- **Nothing was sent anywhere.** No relay is running in this release and no delivery worker exists yet,
  so there is no copy of the journal on a server to delete or retract. The journal, favorites and
  recipes have never left the device except through the export file described above.
- **Apple Health.** Delivery to the Health app is switched off in this release: the connection is listed
  on the screen but cannot be turned on, so no sample this app names has ever been written and there is
  nothing in Health to remove.
- **When Apple Health delivery ships, the erase has to grow.** A written sample is removed by the sync
  identifier the write plan already stamps on it (`[ADR 0002](adr/0002-healthkit-sync.md)`, and the
  write plan in [healthkit-writer.md](healthkit-writer.md)), not by deleting the local row: the Health
  app keeps its own store and the local journal is not its only copy. The erase therefore has to read
  the sync identifiers the journal wrote, delete those samples through HealthKit first, and only then
  drop the local rows — in that order, because once the rows are gone the identifiers are too. Until
  that work ships, no sample exists and the erase does not claim to remove one.
- **The same applies to the relay** when it ships. Outbox operations are deleted with the journal, which
  stops anything further being sent, but a receiver the person configured and owns has its own copy and
  is the person's to clear.

## Checking it

`ios/NutritionCore/Tests/NutritionJournalTests/JournalEraseTests.swift` covers each store: the journal
comes back empty including pending outbox operations and revisions, favorites and recipes come back
empty, a `create()` after an erase succeeds, and a closed store throws its own `.closed` error instead
of reporting a successful erase.
`ios/NutritionCore/Tests/NutritionUITests/ConnectionsPrivacyEraseTests.swift` covers the screen: every
injected store runs, the export file is removed, and a store that fails is reported while the rest
still run.