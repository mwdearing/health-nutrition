# MVP-GAPS traceability: remaining daily-workflow requirements

A requirements traceability check of the ten daily-workflow requirement areas, recorded against the code at
`3bfbee7`. Each area gets one verdict, the `file:symbol` that carries it, the test that would fail if it broke, and
the gap.

The bar used here: **a screen existing is not a behaviour being implemented.** A fixture, a DTO, a column, a view
that renders placeholder text, or a passing schema test is not implementation. "Implemented" means a real code path
plus a test that would fail if that path broke.

The four verdicts in the brief are *implemented*, *partial*, *scaffold* and *unverified*. Two areas have no code of
any kind behind them — not even a type or a fixture — which none of those four describes. Those rows read
**not implemented** rather than *unverified*, because the absence was established by reading the code rather than
failed to be established; calling them unverified would misrepresent the result.

Paths are relative to the repository root. Line numbers are a hint from `3bfbee7`, not a stable anchor.

## Traceability table

| # | Requirement area | Verdict | Implementing `file:symbol` | Test that pins it | Gap |
|---|---|---|---|---|---|
| 1 | User-configured goals | **not implemented** | none. Nearest code answers a different question: `NutritionUI/CoverageLine.swift:46 CoverageLine` counts foods whose value is *unknown*, and `NutritionUI/TodayViewModel.swift:21 defaultTrackedNutrients` is an in-memory constant | none. `NutritionUITests/TodayTests.swift:252 testDefaultLookupMakesEveryFoodUnknown` pins the constant, not a goal | No goal type, no persisted goal store, no goal UI, and no intake-versus-goal comparison anywhere; there is no `goal` token in any Swift source |
| 2 | User-configured units | **partial** | `NutritionDomain/Units.swift:73 UnitRegistry` and `NutritionDomain/Quantity.swift:31 converted(to:)` for domain parsing and exact conversion; `NutritionUI/AddIntakeView.swift:119` picker for a per-entry unit. No preference | `NutritionDomainTests/UnitsTests.swift` (12 tests, incl. `:43 testUnitDimensionsRegistry` and `:170 testUnknownUnitSymbolRejected`). None for a preference | The registry is closed metric/count/IU and rejects `oz`/`tbsp`; every display path prints the stored symbol through `NutritionUI/TodayViewModel.swift:194 DecimalFormatting`; there is no units preference store, no settings screen and no conversion to a user-chosen unit |
| 3 | Meal labels | **scaffold** | `NutritionJournal/JournalTypes.swift:94 Intake.meal` is carried through `NutritionJournal/SwiftDataJournalStore.swift:770`, `NutritionJournal/JournalExport.swift:187`, `NutritionJournal/JournalImporter.swift:350`, `NutritionUI/JournalRepeat.swift:70` and `NutritionUI/LibraryViewModel.swift:36` | none on a producing or rendering path. `NutritionUITests/JournalLibraryTests.swift:364 testFavoriteMealPersistsAcrossReopenAndRepeatCopiesIt` and `NutritionJournalTests/JournalImportTests.swift:211` inject the value first; `NutritionJournalExportTests/JournalExportTests.swift:162` pins the `null` case | The field is free text with no producer and no renderer: every production `Intake(...)` omits `meal:` (`NutritionUI/AddIntakeViewModel.swift:308`, `NutritionUI/TodayViewModel.swift:122`, `NutritionUI/RecipeDetailViewModel.swift:95`), and no view reads it (`NutritionUI/JournalViewModel.swift:63`, `NutritionUI/EntryDetailView.swift`, `NutritionUI/LibraryView.swift:43`) |
| 4 | Reminders | **not implemented** | none | none | Zero notification code: no `UserNotifications` import, no `UNUserNotificationCenter`, no notification entitlement in `ios/HealthNutrition/HealthNutrition.entitlements`, no notification usage description in `ios/HealthNutrition/project.yml`. The only `schedule` hits are HealthKit/relay outbox retry backoff |
| 5 | Previous-day corrections | **partial** | `NutritionUI/EntryDetailViewModel.swift:114 save(components:changeReason:now:)` → `NutritionJournal/SwiftDataJournalStore.swift:852 edit(intakeID:components:product:changeReason:now:)`, reached for any day from `NutritionUI/JournalView.swift:16` via `HealthNutrition/Sources/RootView.swift:64` | `NutritionUITests/JournalLibraryTests.swift:208 testEditCreatesRevisionWithOneEditCall`; `NutritionJournalTests/JournalStoreTests.swift:53`. `NutritionUITests/TodayTests.swift:179` pins that Today shows only the local day | An existing entry's date and time cannot be changed: `edit` takes no `occurredAt` (`NutritionJournal/JournalTypes.swift:288`) and never touches `IntakeRecord.occurredAt`. Only a *new* entry can be back-dated, through the `DatePicker` at `NutritionUI/AddIntakeView.swift:124`. Today rows are also not tappable (`NutritionUI/TodayView.swift:62`) |
| 6 | Configured quick-water volume | **scaffold** | `NutritionUI/TodayViewModel.swift:117 quickAddWater(milliliters: Decimal = 250, now:)`, called argument-free from `NutritionUI/TodayView.swift:34` | `NutritionUITests/TodayTests.swift:69 testQuickAddWaterCreatesOneIntakeAtRevisionOneAndQueuesOutbox` pins the literal 250; `:86 testQuickAddWaterUsesGivenAmountOnce` covers the parameter no UI reaches | 250 mL is hard-coded in three places — the default argument at `TodayViewModel.swift:117`, `Text("Add 250 mL water")` at `TodayView.swift:36`, and the accessibility label at `TodayView.swift:38`. There is no settings store (`UserDefaults`/`@AppStorage` appear nowhere in Swift sources), no settings screen, and no injection point on `TodayViewModel.init` |
| 7 | Separate summaries | **partial** | `NutritionUI/TodayViewModel.swift:68-108 load(now:)` derives the water total (`:84`) and one `CoverageLine` per nutrient (`:104`); `NutritionUI/CoverageLine.swift:68 make(nutrient:values:)` keeps each nutrient's counts separate | `NutritionUITests/TodayTests.swift:190`, `:201`, `:210`, `:241`, `:302`, `:325`; `NutritionUITests/JournalLibraryTests.swift:111`, `:157` | Nothing is persisted: no summary record exists in any of the four schema versions, and every figure is recomputed and discarded on each load. There is no scope other than today, and no nutrient *amount* is ever summed — `TodayViewModel` counts coverage only, so "total protein today" does not exist in the product |
| 8 | Revision history / provenance | **partial** | Revisions: `NutritionJournal/SwiftDataJournalStore.swift:852 edit` → `:1329 appendRevision`, listed at `NutritionUI/EntryDetailView.swift:64` from `NutritionUI/EntryDetailViewModel.swift:82`. Provenance: `NutritionJournal/JournalTypes.swift:161 ProductDefinition`, exported by `NutritionJournal/JournalExport.swift:73 JournalExportProvenance` | `NutritionJournalTests/JournalStoreTests.swift:53`, `:200`, `:309`, `:123`; `NutritionUITests/JournalLibraryTests.swift:190`; `NutritionJournalExportTests/JournalExportTests.swift:317` | Revisions are implemented; provenance is recorded, exported and import-validated but never shown on a journal entry — `NutritionUI/EntryDetailView.swift` has three sections and none shows origin, version, basis or barcode. A label capture records `catalogOrigin` and a content hash (`NutritionUI/LabelCaptureViewModel.swift:525`) but no scan identifier to show. The `History` section itself has no test: no test renders `EntryDetailView`, only its view model |
| 9 | Destination status | **partial** | `NutritionJournal/JournalTypes.swift:11 DestinationState` and `:216 DestinationProjection`; rendered per intake at `NutritionUI/EntryDetailView.swift:49` from `NutritionUI/EntryDetailViewModel.swift:99` and `:194` | `NutritionUITests/JournalLibraryTests.swift:190`, `:202 testDestinationStateTextCoversEveryState`; `ConnectionsPrivacyTests/ConnectionsPrivacyViewModelTests.swift:88` | One word plus an icon per intake is the whole surface. Queue depth, the suspension reason (`NutritionJournal/SwiftDataJournalStore.swift:1154`) and delivery outcome history reach no view, and `rearmDelivery` (`SwiftDataJournalStore.swift:1260`) has no production caller — so `needsAttention` is terminal in the app. `NutritionUI/ConnectionsPrivacyView.swift:74,83` are literal `.disabled(true)`. The outbox is never drained: `HealthNutrition/Sources/AppServices.swift:79` passes `enabledDestinations: []` and no code calls `runOnce` outside tests |
| 10 | Retention / recovery | **partial** | Recovery: `NutritionJournal/JournalExport.swift` exporter, `NutritionJournal/JournalImporter.swift:101 importExport(_:into:favorites:)`, `NutritionJournal/SwiftDataJournalStore.swift:908 restore(_:)`, `:1067 eraseAll()`. Retention: none | `NutritionJournalTests/JournalImportTests.swift:365 testANonEmptyStoreIsRefusedRatherThanMerged`; `NutritionJournalTests/JournalEraseTests.swift` (7 tests); `NutritionUITests/ConnectionsPrivacyEraseTests.swift` (12 tests); `NutritionUITests/TodayTests.swift:119`, `:132` | Retention is absent: no `retention`, `prune`, `expire`, `ttl` or `maxAge` code for journal data exists, so revisions, tombstones, acknowledged outbox rows and product snapshots accumulate without bound and no document states that. Recovery is bounded: restore runs only into a completely empty journal, `undoRestore` is internal import compensation with no UI, and erase is irreversible by design (`ConnectionsPrivacyViewModel.swift:126`) |

## Summary

- **Implemented end to end with a failing-on-break test:** none of the ten. Areas 5, 8 and 10 contain genuinely
  implemented machinery (entry amendment, revisions, export/import/erase) with the surrounding requirement missing.
- **Partial:** 2, 5, 7, 8, 9, 10.
- **Scaffold:** 3, 6.
- **Not implemented at all:** 1, 4.
- **Unverified:** none. Every area was established from the code.

## Notes on the evidence

Two things a reader should know when re-running this check.

- Absence was established by exhaustive search, not by sampling: `goal`, `remind`, `notif`, `AppStorage` and
  `UserDefaults` return zero matches across `ios/NutritionCore/Sources` and `ios/HealthNutrition/Sources`. The only
  occurrences of `Settings.swift` and `@AppStorage` in the repository are synthetic fixtures inside
  `scripts/tests/test_check_privacy_manifest.py:159`, which assert that such code would *fail* CI.
- "The model can store it" and "the user can see it" are different guarantees, and the areas above separate them
  deliberately. Areas 3, 8 and 9 all persist or model the data and none of the three surfaces it.

## Related

Each proven gap is tracked as its own bounded issue, `MVP-GAPS-01` through `MVP-GAPS-10`, one per row above. Issues
[92](https://github.com/mwdearing/health-nutrition/issues/92) (documentation synchronisation) and
[36](https://github.com/mwdearing/health-nutrition/issues/36) (relay outbox delivery) already cover adjacent ground
and are not duplicated here.