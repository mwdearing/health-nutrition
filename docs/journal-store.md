# Journal store

The journal lives in the `NutritionJournal` SwiftPM target and uses SwiftData
(see [ADR 0001](adr/0001-persistence.md)). It only records and queues work; it has no
HealthKit, network or worker code.

## Model

- `Intake`: id (lowercase UUID), category, time, time zone, lifecycle (`active` or
  `deleted`), current revision.
- `IntakeRevision`: numbered from 1, +1 per edit; components (slug id
  `[a-z0-9][a-z0-9._-]{0,63}`, exact decimal amount, unit), an optional product
  snapshot id, a change reason, and the instant and zone it was written with.
  Revisions are never rewritten.
- `ProductDefinition`: an immutable snapshot. Editing a product creates a new snapshot
  id; old revisions keep the snapshot they used. Re-using an id with different content
  is refused. It also carries the nutrient values the product states, on the basis
  `labelBasis` names, as JSON decimal text (every state is spelled out: `known`, `unknown`,
  `notApplicable`, `belowThreshold`). A nutrient the product does not state is absent, which
  reads as unknown and never as zero. A snapshot written before this column existed reads
  back as a product that states nothing.
- `DestinationProjection`: per revision and destination, the desired action and its
  state: `pending`, `inProgress`, `succeeded`, `needsAttention`, `disabled`.
  A later revision or a delete marks older projections as not current.
- `OutboxOperation`: `upsert` or `delete` per enabled destination; the operation id
  (lowercase UUID) is the idempotency key.

Amounts are `Decimal` in memory and decimal text on disk, never binary floating point.

## Schema versions

`JournalSchemaV1` is the first released schema and is never changed again. `JournalSchemaV2` adds the
optional nutrient column to the product record, and `JournalMigrationPlan` carries a lightweight stage
from V1 to V2, so an existing `journal.store` is migrated in place when it is next opened. A row that
has no nutrient payload reads back as a product that states nothing, and re-saving that same product
fills the values in rather than refusing the snapshot as a conflict; every other difference under the
same snapshot id is still a conflict.

`JournalSchemaV3` adds the optional suspension reason to the outbox record, and its stage from V2 is
**custom** because a lightweight stage cannot populate a column: the V2 store recorded a suspension only
on the projection, so an upgrade would silently release every denied operation. The backfill runs in
`didMigrate`, not `willMigrate`, because the context handed to `willMigrate` is still bound to the old
schema, where the new column does not exist — fetching V3 models there fails and the container never
finishes opening.

`JournalSchemaV4` adds the deletion instant and the recorded link snapshot to the outbox record, and
`JournalSchemaV5` adds the instant and zone to the revision record. Both stages are lightweight and need
no backfill: every column they add is optional and describes something a row written before it cannot
have, so nil is the honest reading rather than a value waiting to be recovered.

The import path changed nothing here: a restore writes columns the existing rows already have, so V1 and V2
stay exactly as they are and no migration stage was added. A restored tombstone carries an empty category,
because the export records a deleted entry's id, revision, time and time zone but not its category, and
inventing one would be data this build does not have.

## Transaction rule

Every write (`create`, `edit`, `delete`) is one `ModelContext.save()` covering the
revision, the projections and the outbox operations. A failure rolls the context back,
so none of them is left behind. Each operation uses a fresh context with autosave off.
Writes are serialized by a store-wide write lock held through the save, so concurrent edits get consecutive revision numbers. `pendingOutbox()` returns operations by intake, revision, then upsert before delete, then destination.
A disabled destination gets a `disabled` projection and no outbox operation.

A restore (`restore(_:)`, see [Journal export](journal-export.md)) is one save too, covering the product
snapshots, every intake with all of its revisions and every tombstone. It writes **no** projection and
**no** outbox operation: a restored entry is history the destinations were already sent once, so it must
not be delivered again. That is why it is a separate method and not a flag on `create` - creating an entry
means the person just ate something and it has to reach Health. `JournalRestoreTarget` is a separate
protocol from `JournalStore` for the same reason: the normal create/edit/delete behaviour cannot change.
The restore only runs into a journal with no intake rows at all, active or deleted, and it reads that
predicate **inside** its own `commit` closure, under the same write lock as the inserts, throwing
`JournalImportError.notEmpty` from there. A check before the save would leave a window in which another write
creates an entry and the restore joins it, which is the merge the importer refuses; there is no merge.

A restore returns a `JournalRestoreReceipt` naming, per entry, the lifecycle, the current revision and the
revision numbers that are its own, and `undoRestore(_:)` removes exactly those rows. It is compensation, not
a reset: an entry edited or deleted after the restore no longer looks the way the restore left it, so the undo
refuses with `JournalImportError.corrupt` instead of throwing that work away to make the journal look empty.
A product snapshot the store already held is not in the receipt and is never touched. A snapshot the file
describes is matched against what the store holds by identity alone: its stored nutrient values are kept,
because the document carries none and an import must not empty the ones the journal was reading, while a
stored row that states none is filled in from the plan. Only two sets that both state values and differ are a
`snapshotConflict`, as is a *different* product under a snapshot id the store holds.

## Correcting when an entry was eaten

`edit` also takes `occurredAt` and the `timeZoneIdentifier` that goes with it. Given both, the new revision carries the
corrected instant and the intake's own row moves with it in the same save; given neither, the time is left exactly as
it was, so an amounts-only edit cannot move an entry by accident. Given one without the other, what was not corrected
is kept: a new date with the entry's own zone, or a new zone with the entry's own instant. `IntakeRecord` already held
both fields, so this part needed no schema version.

**Each revision also keeps a copy of the time it was written with**, which is what `JournalSchemaV5` adds to
`RevisionRecord`. `IntakeRecord` is the only other place the instant lives, and it moves on a correction, so
a revision that is still queued has to be able to read its own instant back: rebuilding revision 1 from the
entry's current row would send the corrected instant under revision 1's own `operation_id` and payload hash,
which the receiver reads as a conflict rather than the duplicate it is. A row written before the column reads
as nil, meaning "the entry's current time" — the only instant such a row can offer. The export format does
not carry a time per revision, so a restored revision reads as nil for the same reason.

**The correction is a new revision, never an update to a delivered one.** The encoder digests `occurred_at` per
(intake, revision), so a revision that has already been sent describes the instant it was written for: changing the
row underneath it would leave a delivered revision claiming a moment that is no longer true. Everything else the
existing machinery already does therefore still holds — the previous revision is kept, the superseded projections are
not updated, a new upsert is queued for every enabled destination, and the journal then reads the entry under its
corrected day. Delivery scheduling, the retry policy, every threshold, the encoder and the digest rules are untouched;
what changes is which revision is current.

The upsert payload hash covers the instant and the zone as well as the amounts, because "40 g of oats" and "40 g of
oats, eaten at 19:00" are different facts and a receiver deduplicating on that hash has to be able to tell them
apart. The hash is a change detector, so the timestamp is written as the whole-second UTC text the contract itself
uses.

## Usage constraints

The app must use ONE `SwiftDataJournalStore` per database file. The write lock is per instance, so two instances on the same file are unsupported and can assign duplicate revision numbers.

## Delivery acknowledgement

`JournalOutboxDelivery` refines `JournalStore` with the two calls a delivery worker needs to record
what happened to one operation. It is a refinement rather than part of `JournalStore` because reading
the journal is something every implementation can do, while recording a delivery needs the store that
owns the outbox; a read-only stand-in (an export source, a view model's test double) should not have to
invent it. `SwiftDataJournalStore` is the implementation.

- `acknowledge(operationID:at:)` stamps `acknowledgedAt`, clears `nextAttemptAt` and moves the
  current projection for that revision and destination to `succeeded`. Acknowledging an operation that
  is already acknowledged is not an error: a worker that crashed after writing but before recording
  the delivery will deliver again, and that second delivery has to be recordable.
- `recordFailure(operationID:retryAt:needsAttention:)` grows `attempts` by one, sets `nextAttemptAt`,
  and puts the projection in `pending` or, with `needsAttention`, in `needsAttention`. An acknowledged
  operation is left alone.
- `suspendedOperationIDs()` returns the pending operations whose projection is `needsAttention`.
  A suspension cannot be read off the operation: `nextAttemptAt == nil` means both "do not retry" and
  "due now", so only the projection distinguishes them. The match **ignores whether the projection is
  current**: an edit supersedes the earlier projections but leaves their operations pending, so a denied
  revision must stay suspended after its projection goes noncurrent, or every run retries the denied
  write and blocks the newer revision forever.
- `rearmDelivery(operationID:)` clears the suspension and makes the operation due again. Re-arming is a
  separate call on purpose: it is a person's decision that a denial has been resolved. It clears the
  projection **including a superseded one**, because that projection is where the suspension is recorded;
  every other projection update touches current projections only.

Both writes are single saves through the same `commit` path as every other write, so a failure rolls
back and the injected-failure test flag covers them. `pendingOutbox()` excludes acknowledged operations,
so a delivered operation is never offered again.

**A projection update matches the operation's action as well as its intake, revision and destination.**
Deleting an intake does not increment its revision, so the queued upsert and the queued delete share all
three and differ only by action. Matching without the action would let acknowledging the stale upsert
mark the delete `succeeded`, and the app would then report a finished retraction while the samples are
still in Health.

Only **current** projections are updated, so a superseded one keeps its state — a stale upsert that is
acknowledged after a delete leaves its own noncurrent projection as `pending`. That is deliberate: what
a later revision is doing matters more than what an operation that has already been superseded did.

No schema change was needed: the three columns already existed.

See [healthkit-writer.md](healthkit-writer.md) for the worker that calls them and the retry policy.

## Testing

Tests run on real on-disk stores in a unique temporary directory. A test flag makes the
next write fail after its inserts and before the commit.
