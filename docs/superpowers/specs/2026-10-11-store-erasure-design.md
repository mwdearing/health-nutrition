# Nutrition store protection and local erasure design

Status: design for owner review; implementation has not been approved by this document.

This design is the coordinated local-store erasure work for #119, covering the related #228 concern. It keeps one erase flow for the four local stores, states the limits of file removal plainly, and makes the protection policy depend on measurements from a real iOS device. It does not create a competing project or claim secure or forensic deletion.

## Current source facts and evidence limits

`AppServices.make(directory:)` opens four independent SwiftData stores in Application Support: `journal.store`, `favorites.store`, `recipes.store`, and `goals.store` ([AppServices.swift](../../../ios/HealthNutrition/Sources/AppServices.swift)). `SwiftDataJournalStore`, `SwiftDataFavoritesStore`, `SwiftDataRecipeStore`, and `SwiftDataGoalStore` each own an optional `ModelContainer`; their `close()` methods drop that reference ([journal](../../../ios/NutritionCore/Sources/NutritionJournal/SwiftDataJournalStore.swift), [favorites](../../../ios/NutritionCore/Sources/NutritionJournal/JournalFavorites.swift), [recipes](../../../ios/NutritionCore/Sources/NutritionJournal/SwiftDataRecipeStore.swift), [goals](../../../ios/NutritionCore/Sources/NutritionJournal/SwiftDataGoalStore.swift)). Store methods construct short-lived `ModelContext` instances internally, and the app's store protocols return value types rather than exposing SwiftData models or contexts. Each store currently has an `eraseAll()` row-deletion implementation; the screen invokes the erasers independently, so a failure can leave only some stores erased.

The app graph retains the four store wrappers for its lifetime. `AppServices` also retains view models that cache values from them. `RootView` owns additional recipe navigation/list state and transient add/detail flows. The current erase-generation handler resets recipe routes and add flow and reloads Today, Journal, Library, goals, and the first-day checklist; it does not replace the `AppServices` graph. Any store lifecycle change must preserve that graph's references or deliberately rebuild the full graph and its routes.

Imports/restores run on a background executor and already have an `ImportGate` that refuses new imports during erase and waits for in-flight restores ([ConnectionsPrivacyViewModel.swift](../../../ios/NutritionCore/Sources/NutritionUI/ConnectionsPrivacyViewModel.swift)). `RootView` owns additional route and cached model state ([RootView.swift](../../../ios/HealthNutrition/Sources/RootView.swift)). The current source has no `BGTask` registration. HealthKit delivery is only queued in debug builds and is driven by app code ([AppServices.swift](../../../ios/HealthNutrition/Sources/AppServices.swift)); the relay destination is disabled. Future delivery writers must join the same lifecycle gate before they can run. These are source facts, not measurements of locked-device behavior.

No real iOS device measurement is available for this design. The repository's SwiftData configuration specifies store URLs and disables CloudKit; it does not request a file-protection class or establish the attributes SwiftData/iOS applies to the database and sidecars. There is no device evidence here for current protection attributes, WAL/SHM creation or residue, locked reads/writes, open-handle behavior after unlink, or post-erase relaunch. Do not treat defaults inferred from source or simulator output as device evidence.

## Approaches considered

1. **Keep row deletion and apply an explicit protection class.** This is the smallest change and preserves all current container and view-model identities. It does not remove old database pages or guarantee that deleted values disappear from the main file or WAL. It is insufficient for the requested physical local erase.
2. **Quiesce the app, close all four containers, remove each store and its SQLite companions, then reopen the same paths.** This retains the current store wrapper and view-model graph. A durable erase-intent record makes restart recovery possible. It removes the app's database files from their paths, but does not promise flash-block sanitization, removal from backups/snapshots, or deletion of copies outside the app.
3. **Write to a fresh generation of four store paths and switch the app graph, then remove the old generation.** This gives a clean namespace switch, but requires a larger dependency-graph and migration design, and still cannot revoke a file descriptor or promise forensic deletion of the old generation. It adds complexity without an established need in the current source.

**Recommendation:** approach 2, subject to the device protocol below. It best fits the existing app: stores are app-owned wrappers, contexts are created internally, and view models already share stable store interfaces. Preserve the wrapper objects, replace only their containers after successful removal, and use the existing erase-generation refresh path plus an explicit audit of every cached route/model. If device testing shows that SwiftData retains a usable old container or that a stale operation can still write after the gate drains, stop and revisit approach 3 before implementation.

## Proposed protection policy, conditional on measurements

The tentative target is `NSFileProtectionComplete` for all four main store files and every SQLite sidecar the app observes. Under this policy, the app must treat a locked-device store operation as unavailable, fail closed, and retry only after protected data is available. The source has no registered background task and release builds queue neither HealthKit nor relay delivery, so there is no source-backed requirement to keep these stores available while locked.

Before implementation, measure normal and erase behavior on the supported physical iPhone and iOS build. If an owner-approved operation must read or write these stores after the first unlock while the device is locked, compare `NSFileProtectionCompleteUntilFirstUserAuthentication` and document the weaker locked-device availability before choosing it. Do not silently weaken the class to make a test pass. `NSFileProtectionCompleteUnlessOpen` is not the recommendation: whether a container or SQLite handle remains open would then affect the protection boundary and erase result. The chosen class must be explicit, applied and verified for the database and companions after creation/recreation, and covered by the device matrix.

The class protects files under the operating system's data-protection model; it is not app-level encryption and is not a claim that previously written flash blocks are overwritten.

## Erase lifecycle

Implement a single app-level erase coordinator, owned with the store graph, with states `ready`, `erasing`, and `recoveryRequired`. It must serialize local mutations, imports/restores, and delivery against erase. Every write entry point—including ordinary store mutations, imports, HealthKit delivery acknowledgements, and any future relay/outbox worker—must acquire an operation lease before it can touch a store. Erase first closes admission to new leases, cancels or refuses queued work, and waits for existing leases to drain with a bounded timeout. A timeout refuses erasure before any store file is touched, matching the existing import timeout behavior. A timed-out or rejected operation must not later start from a stale callback.

Once quiescent:

1. Persist a small, protected erase-intent marker before closing stores. It contains only the operation state and component completion flags, never personal store contents. Startup checks it before opening a store or restoring the community session.
2. Run the local account cleanup added by PR-06 (`discardLocalSession()` backed by Keychain removal) while session restoration and account actions remain gated. Never call server logout, account deletion, or shared-label retraction. A Keychain error remains an incomplete local erase; do not show success or allow automatic session restoration while that component is pending.
3. Close all four store wrappers and drop every app-owned reference to in-flight contexts by waiting for leases first. Do not expose containers or contexts outside the store wrappers. If any close or drain fails, keep the app in recovery and do not reopen a partially erased graph.
4. For each canonical store path, attempt removal of the main database and the exact SQLite companion paths for that store (at minimum `-wal` and `-shm`; also remove a present rollback journal if observed). Never sweep unrelated files or the whole Application Support directory. Attempt every store even if one path fails, and persist per-store completion so relaunch can safely retry idempotently.
5. If any store file remains or cannot be removed, retain the erase marker, keep store access closed, show incomplete erase with retry/relaunch guidance, and do not recreate a container over a mixed state. On next launch, retry cleanup before opening stores. Do not claim successful erase until every required component has completed.
6. After all four paths and companions are absent, recreate the four containers at the same canonical paths, set and verify their selected protection class, then remove the marker and reopen operation admission. A creation/protection failure leaves recovery required; it must not silently open a default-protection store.
7. Clear account-facing state and refresh the existing graph. Close selected entry detail and all recipe/add/edit routes; clear any held selection or copied recipe; reload Today, Journal, Library/favorites, recipes, Goals, first-day checklist, and the Connections erase/export state. Debug delivery status must be refreshed against the reopened journal store. The erase generation is emitted only after replacement succeeds.

The wrapper identity remains stable, so `TodayViewModel`, `JournalViewModel`, `LibraryViewModel`, `GoalsViewModel`, `FirstDayChecklistModel`, `ConnectionsPrivacyViewModel`, `RecipeListViewModel`, the HealthKit worker and its debug status continue to point at the same wrappers, now backed by fresh containers. Any screen that holds copied values or an asynchronous result must be explicitly invalidated or closed as listed above. A stale wrapper reference must not bypass the coordinator: it is gated and resolves only the current container. The implementation must audit all writers and model caches when a new store consumer is added.

`ModelContainer` does not provide an app-facing close operation in this source. Dropping the wrapper's reference is the available lifecycle seam; it is not by itself proof that SwiftData has released every underlying descriptor. Device testing must exercise retained wrapper/context scenarios and file residue. The design does not use SQLite `PRAGMA`, raw SQLite writes, `VACUUM`, or undocumented manipulation behind SwiftData.

## Partial failure and recovery semantics

There is no cross-file transaction across four independent stores, the Keychain, preferences, reminders, and exports. The durable intent marker is the recovery boundary, not a promise of all-or-nothing physical deletion. Report failure if Keychain removal, any store/sidecar removal, container recreation, protection verification, or required local cleanup fails. Continue independent erasers where safe, but do not reopen a failed or mixed store set. If only Keychain cleanup is pending and all four stores are clean, the app may show a restricted recovery state that keeps account restore and account writes disabled until the Keychain step succeeds. On launch, recover the marker before account restoration or any store access. Retrying completed removals and a completed local-session discard is idempotent.

If the process is killed at any point after intent is durable, launch recovery repeats unfinished steps before normal service construction. If writing the intent itself fails, do not start container closure or file deletion; report that no store erasure was attempted. A failed erasure is never described as complete.

## Synthetic physical-device measurement protocol

Run this only on a designated physical iPhone with a debug/test build and synthetic records that contain unmistakable fake tokens, never personal data. Record the app build, iOS version, device model identifier, selected protection class requested, and test run identifier. Redact device identifiers from any public artifact; keep only the attributes needed to reproduce the run. A simulator can help develop the harness but cannot satisfy this protocol.

1. Start from a clean test installation. Write one synthetic sentinel to each store: a journal entry, favorite, recipe, and goal. Add enough journal writes to cause SQLite sidecar creation. Record, per canonical store path, existence, file size, file-protection attribute requested and observed, and whether main database, `-wal`, `-shm`, or rollback-journal files exist. Capture the attributes after writes, after app backgrounding, and after relaunch; do not infer a sidecar attribute from the main database attribute.
2. With the app foregrounded, lock the device and attempt only the approved read/write probes through the app's stores. Record success or the exact protection error for each store. Repeat after first unlock and after a subsequent lock. Separately test an in-flight synthetic import and delivery operation when locking begins; verify the lifecycle gate drains or refuses it and cannot create a post-erase write.
3. Retain references to the old store wrappers and any test-created context that the harness can retain without adding production escape hatches. Begin erase while synthetic writes are queued/running. Verify that admission closes, old operations drain or time out before deletion, stale references cannot read sentinel rows or write after erase, and no callback repopulates any store.
4. After erase completes, enumerate each exact main/sidecar path and record which remain. Verify the four recreated stores are empty through normal app reads, then terminate and relaunch and verify they remain empty. Create one new synthetic row per store after erase and verify each persists across another relaunch. Record protection attributes for every recreated file and sidecar.
5. Inject a deterministic file-removal failure for one path. Verify the user sees incomplete erase, all other paths are attempted, no container opens over a mixed old/new set, the durable marker survives termination, and retry/relaunch completes before normal access. Separately inject Keychain cleanup failure and verify there is no success result and session restoration remains blocked.
6. Save a concise run record with pass/fail and raw measured attributes/residue for every store. These are the only evidence that can establish device behavior. If the device or harness is unavailable, mark every device result unknown and leave class choice and implementation approval pending.

The device protocol can demonstrate which app-visible files remain and whether this app can read/write through tested handles. It cannot prove that NAND flash cells, filesystem snapshots, system backups, crash dumps, or recipient copies have been physically purged.

## Validation matrix for implementation approval

| Scenario | Required result |
| --- | --- |
| Device files after normal writes and after erase | Actual protection attributes recorded separately for all four stores and every observed sidecar; after successful erase the named store paths and companions are absent before fresh containers are created. |
| Retained old references | Old wrapper references and any harness-retained context/reader cannot read sentinel data or write/repopulate after container replacement; in-flight leases either drain before deletion or cause erase to refuse before touching files. If SwiftData keeps a retained context usable after file removal, approach 2 is not approved for implementation. |
| Relaunch | Successful erase relaunches with all four stores empty; interrupted/partial erase recovers from the durable marker before any store opens or account restore runs. |
| Post-erase writes | New synthetic journal, favorite, recipe, and goal writes succeed and persist after relaunch under the same selected protection policy. |
| File deletion failure | All independent path removals are attempted; result is incomplete, no mixed stores reopen, and retry after termination finishes recovery before app access. |
| Keychain failure | Result is incomplete; other safe local erasers still run; account identity/session restoration and account writes remain blocked until local session discard succeeds. |
| Locked behavior | The selected class matches measured foreground/background requirements. Under `Complete`, operations fail closed while protected data is unavailable and recover after unlock; any alternate class has an explicitly approved and measured locked-state contract. |
| Stale async work | An import completion, delivery acknowledgement, view-model task, or old account response cannot recreate data or mutate a replacement container after erase. |

## User-facing claim boundary

Copy may say the app closes and removes its four local store files and SQLite companions, then creates empty stores again, if the implementation and device matrix verify that behavior. It must say that deletion is not guaranteed to overwrite prior flash blocks and does not remove system backups/snapshots or copies already exported, shared, delivered to Apple Health, a relay, or a server. It must not say “securely erased,” “forensically erased,” or that `VACUUM` makes erased data unrecoverable. Existing public copy remains unchanged until behavior is implemented, measured, and reviewed.

## Decisions required before implementation

- Review and approve approach 2 or select another approach after the physical-device evidence is available.
- Choose `NSFileProtectionComplete` if measured app flows can fail closed while locked; approve `NSFileProtectionCompleteUntilFirstUserAuthentication` only if a demonstrated, owner-approved background requirement needs it.
- Approve the durable erase-intent/recovery state and restricted failure behavior, including the Keychain retry gate from PR-06.
- Approve the exact user-facing wording after the implementation and device measurements establish what files are removed.

Until those decisions and measurements are reviewed, this document is a design proposal only. No implementation, test claim, or changed erase guarantee is authorized by it.
