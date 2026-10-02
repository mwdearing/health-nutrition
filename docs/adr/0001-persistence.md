# ADR 0001: Persistence for the intake journal (SwiftData or Core Data)

Status: Proposed. Decision: pending, Michael decides.

## Context

The nutrition app keeps an append-only journal of intake revisions. Every revision
must be accompanied by an outbox operation (the pending sync message) and the two
must never exist apart: a revision without an outbox row is never synced, an outbox
row without a revision syncs nothing. The store must survive app upgrades (schema
changes), keep working after a failed upgrade, and be readable from background work
such as sync. Amounts are kept as decimal text so no binary floating point is
involved. The minimum platform is iOS 18.

This spike puts one small `JournalStore` protocol in front of two implementations
and runs the same scenarios against both, on real on-disk stores in a unique
temporary directory per test.

## Options

1. SwiftData: `@Model` classes in a `VersionedSchema` (v1, v2) with a
   `SchemaMigrationPlan` and a lightweight stage v1 to v2 (v2 adds a `note` field with a
   default). A fresh `ModelContext` per operation, autosave off.
2. Core Data: an `NSManagedObjectModel` built in code (v1, v2), an
   `NSPersistentContainer` on an SQLite file, automatic lightweight migration with an
   inferred mapping, and `newBackgroundContext()` for reads and writes.

Both options store: `RevisionRecord` (intake id, revision number, payload text,
amount text, and from v2 a note) and `OutboxRecord` (operation id, intake id,
revision number, kind).

Failure injection: a test flag makes the next save insert both rows and then fail
before the commit. The migration failure is a custom SwiftData stage that throws,
and for Core Data a store opened with automatic migration switched off.

## Results

The spike was written without a Swift compiler; the macOS CI run (swift-test job on
the pull request) compiled and ran it. All twelve tests passed (12 executed, 0 failures).

| Case | SwiftData | Core Data |
| --- | --- | --- |
| MigrationV1ToV2KeepsData | pass | pass |
| RevisionAndOutboxCommitAtomically | pass | pass |
| FailedSaveLeavesNeitherRevisionNorOutbox | pass | pass |
| BackgroundContextReadsCommittedData | pass | pass |
| FailedMigrationLeavesStoreReadable | pass | pass |
| ReopenAfterCloseKeepsData | pass | pass |

Notes on what the cases do and do not prove:

- The failed-save case injects the failure after both inserts and before the
  commit. It proves the rollback path, not a real constraint violation or a full disk.
- The failed-migration case behaves differently per store: SwiftData fails inside a
  custom stage, Core Data refuses to open an old file with the new model. Both then
  reopen the untouched file with the v1 schema. Whether SwiftData leaves the file
  unchanged after a throwing stage is exactly what the CI result must show.
- SwiftData requires macOS 14, so the package platform was raised from macOS 13 to 14
  (iOS stays at 18). The spike targets compile in Swift 5 language mode to avoid
  strict-concurrency friction with persistence types; that is a spike shortcut.

## Recommendation

Recommend SwiftData. All six cases pass on both stores, so by the rule set before
the run (SwiftData only if every case passes) it wins on less code and a fit with the
iOS 18 minimum. Caveats: the failure-injection cases prove rollback and an untouched
v1 file, not a real constraint violation or full disk, and the migrations tested are
lightweight; re-run the failed-migration case with a real schema change before the
first release. The `JournalStore` protocol keeps the choice reversible while the app
is small.

## Decision

Pending: Michael decides.

## Consequences

- Whichever store is chosen, the other implementation and the spike targets are
  deleted, and the protocol stays as the seam for the real journal.
- Choosing SwiftData ties data access to model classes and a macro toolchain; choosing
  Core Data keeps a hand-built or editor-built model and untyped key access unless
  wrapped.
- Schema changes after release need a migration test per version either way; the
  failed-migration case above becomes a release gate.
- Outbox and revision stay in one store and one transaction in both options; no
  cross-store design is needed.
