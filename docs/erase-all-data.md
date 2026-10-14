# Erase all data

Status: Current. Reviewed whenever a store is added or a connection starts writing anywhere.

**Settings > Your data** offers **Erase all data** after a confirmation that says what is removed and that the action cannot be undone. Erase runs each local store eraser, resets the app's display preferences and reminder, removes export files the app can still reach, and clears the community session from this phone's Keychain. It does not contact the community server: the server account, shared submissions and any independently approved catalog snapshot remain. It does not remove copies already shared to another app or service.

Code: `ios/NutritionCore/Sources/NutritionJournal/JournalErase.swift` holds the
`JournalErasing` protocol; `ConnectionsPrivacyViewModel.eraseAllData()` runs the
injected local stores and cleanup operations. Erase does not call server sign-out,
account deletion or label retraction.

## What is erased

The four SwiftData stores live under Application Support. Erase deletes rows using the same store containers, which stay open afterwards; it does not close and recreate store files.

| File | Store | Rows removed |
| --- | --- | --- |
| `journal.store` | `SwiftDataJournalStore` | Intake entries, revision history, product snapshots, projections and queued outbox operations, including deletion tombstones. |
| `favorites.store` | `SwiftDataFavoritesStore` | Favorite templates. |
| `recipes.store` | `SwiftDataRecipeStore` | Recipe versions and recipe tombstones. |
| `goals.store` | `SwiftDataGoalStore` | Daily nutrient targets. |

Each store saves its own row deletion. If a store fails, erase reports a partial failure and still attempts the other local cleanup steps. The screen must not report full success when an eraser fails.

### Display preferences

Erase removes all twelve keys owned by `UserDefaultsDisplayPreferences` from the app's defaults domain:

| Category | Keys removed |
| --- | --- |
| Units and quick water (2) | `display.unitSystem`, `display.quickWaterMilliliters` |
| First-run state (3) | `display.hasSeenWelcome`, `display.checklistHidden`, `display.hasReviewedUnits` |
| Daily reminder (2) | `display.reminder.on`, `display.reminder.time` |
| Today goals (2) | `display.goals.hiddenOnToday`, `display.goals.waterDefaultSeeded` |
| Sharing disclosure, separately acknowledged per account (1) | `display.community.disclosureSeen` |
| Vitamins and minerals comparison group (1) | `display.reference.group` |
| Macro split the gram goals follow (1) | `display.goals.macroSplit` |

Removing the keys restores defaults; it does not write replacement values, with one exception: `display.goals.waterDefaultSeeded` is set to true again right after the erase, so the default water goal is not written back into the just-erased goal store. The reminder's pending notification is also removed. The disclosure will be shown again when the relevant account next signs in on this phone.

### Other local cleanup

- The local Keychain session stored on this phone is cleared. A Keychain failure is reported as a partial erase, while other local erasers still run. This is local credential removal only; no server logout or account deletion request is made.
- Export files named `journal-export-….json` in the temporary directory are removed, including files left by an earlier app launch. A file that cannot be deleted is reported as a failed cleanup.
- The supplement list's times and days (`supplementStack.schedules` in the app's defaults domain) and the times each Taken was for (`supplementStack.taken`) are removed by `UserDefaultsSupplementStackStore`. The items themselves are favorites and go with `favorites.store`.
- The screen clears its export state and entry count when erase begins so it does not keep offering data that is being removed.
- Saved meals (the `library.savedMeals.v1` key in the app's defaults domain, and the `library.savedMeals.restoreReceipt.v1` key a restore leaves) are removed by their own eraser. After a successful erase the saved meals list is read again and any Undo offer for a logged meal is dropped. See [Saved meals](saved-meals.md).

## The widgets' summary

The Today widgets read a small summary file in the App Group container (see [Widgets](widgets.md)). Erase all
data removes that file and asks the widgets to refresh, so they show "Nothing logged today".

## What remains

- **The community server account and submissions.** Local erase does not call the server. Use account controls to sign out or delete an account. Account deletion removes that profile and its submissions; an independently approved owner-reviewed catalog snapshot can remain without contributor identity.
- **Export copies outside the app.** A file shared through the system share sheet belongs to Files, mail, cloud storage or another destination. This app no longer has a handle to that copy and cannot remove it.
- **Apple Health.** After the person connects Apple Health in Settings and allows it, nutrients from real logged food and water entries are written to HealthKit; a debug build's HealthKit screen can also write separate test samples. Erasing local rows does not remove HealthKit samples already written. HealthKit has its own store.
- **HealthRelay.** It is unavailable in this version, so there is no active relay destination for this erase to contact.

Deleting rows from the existing store containers is a logical app-level erase. This documentation does not promise a forensic wipe, a particular file-protection class or that old database bytes cannot be recovered. Device-level protection and physical erase behavior have not been established by this change.

## Checking it

`ios/NutritionCore/Tests/NutritionJournalTests/JournalEraseTests.swift` covers each store: the journal comes back empty including pending outbox operations and revisions, favorites and recipes come back empty, a `create()` after an erase succeeds, and a closed store throws its own `.closed` error instead of reporting success.
`ios/NutritionCore/Tests/NutritionUITests/ConnectionsPrivacyEraseTests.swift` covers the screen: every injected store runs, every reachable export file is removed, a file that cannot be deleted is reported as a failed erase, and a local account cleanup failure is reported while the other erasers still run. `AccountViewModelTests.swift` covers delayed restore/sign-in/profile replies after erase. `AppServicesEraseTests.swift` verifies the app supplies its local account cleanup hook without calling server sign-out or account deletion.
`ios/NutritionCore/Tests/ConnectionsPrivacyTests/ConnectionsPrivacyPreferenceTests.swift` covers the display preferences: the owned keys are removed from the defaults domain by the erase, the screen goes back to its defaults, and the in-memory implementation clears the same way.
