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

- Every journal export this app wrote into the temporary directory, found by its
  `journal-export-….json` name rather than by the one file the screen happens to remember. The app can
  be terminated after an export and relaunched into a screen that has no URL for the file it left, so
  the erase sweeps the directory. A file it cannot delete is reported as a failed erase rather than
  quietly skipped. See [journal export](journal-export.md).
- The screen's own state: the entry count goes back to zero and the export is no longer offered.

The stores stay open afterwards. The app carries on with an empty journal, and a new entry, favorite
or recipe can be written straight away. If one store cannot erase, the others still run and the screen
says so, because being told the erase worked when it did not would be the worse failure.

An exported file the person already shared out of the app is a copy the app no longer has a handle
on. The erase cannot reach it; that is what sharing it in the first place meant.

## What is not erased, and why

- **A copy you already shared or saved somewhere else.** Sharing an export through the system share
  sheet hands it to Files, mail, cloud storage or another app, and that app keeps its own copy. The
  erase cannot reach it: the app has no handle on where the share sheet put it. The button says so, in
  the footer and again in the confirmation, because erasing the local journal and assuming the shared
  copy went with it would leave it behind without the person knowing.
- **The app sent nothing to any server by itself.** No relay is running in this release and the
  delivery worker writes to Apple Health only after a person turns Health delivery on, so there is no
  server-side copy of the journal to delete or retract.
- **Apple Health.** Delivery is off in every release build: the store is opened with no enabled
  destinations, so no HealthKit operation is ever queued and no sample this app names has ever been
  written. There is nothing in Health to remove. A debug build queues HealthKit operations, so a debug
  erase can leave samples behind — the worker acknowledges nothing it did not deliver, and the erase
  does not retract through HealthKit yet.
- **When Health delivery is turned on, the erase has to grow.** A written sample is removed by the sync
  identifier the write plan already stamps on it (`[ADR 0002](adr/0002-healthkit-sync.md)`, and the
  write plan in [healthkit-writer.md](healthkit-writer.md)), not by deleting the local row: the Health
  app keeps its own store and the local journal is not its only copy. The erase therefore has to read
  the sync identifiers the journal wrote, delete those samples through HealthKit first, and only then
  drop the local rows — in that order, because once the rows are gone the identifiers are too. While
  delivery is off, no sample exists and the erase does not claim to remove one.
- **The same applies to the relay** when it is turned on. Outbox operations are deleted with the journal, which
  stops anything further being sent, but a receiver the person configured and owns has its own copy and
  is the person's to clear.

## Checking it

`ios/NutritionCore/Tests/NutritionJournalTests/JournalEraseTests.swift` covers each store: the journal
comes back empty including pending outbox operations and revisions, favorites and recipes come back
empty, a `create()` after an erase succeeds, and a closed store throws its own `.closed` error instead
of reporting a successful erase.
`ios/NutritionCore/Tests/NutritionUITests/ConnectionsPrivacyEraseTests.swift` covers the screen: every
injected store runs, every export file in the temporary directory is removed including one the screen
never wrote, a file that cannot be deleted is reported as a failed erase, and a store that fails is
reported while the rest still run.