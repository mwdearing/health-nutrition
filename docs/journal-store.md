# Journal store

The journal lives in the `NutritionJournal` SwiftPM target and uses SwiftData
(see [ADR 0001](adr/0001-persistence.md)). It only records and queues work; it has no
HealthKit, network or worker code.

## Model

- `Intake`: id (lowercase UUID), category, time, time zone, lifecycle (`active` or
  `deleted`), current revision.
- `IntakeRevision`: numbered from 1, +1 per edit; components (slug id
  `[a-z0-9][a-z0-9._-]{0,63}`, exact decimal amount, unit), an optional product
  snapshot id and a change reason. Revisions are never rewritten.
- `ProductDefinition`: an immutable snapshot. Editing a product creates a new snapshot
  id; old revisions keep the snapshot they used. Re-using an id with different content
  is refused.
- `DestinationProjection`: per revision and destination, the desired action and its
  state: `pending`, `inProgress`, `succeeded`, `needsAttention`, `disabled`.
  A later revision or a delete marks older projections as not current.
- `OutboxOperation`: `upsert` or `delete` per enabled destination; the operation id
  (lowercase UUID) is the idempotency key.

Amounts are `Decimal` in memory and decimal text on disk, never binary floating point.

## Transaction rule

Every write (`create`, `edit`, `delete`) is one `ModelContext.save()` covering the
revision, the projections and the outbox operations. A failure rolls the context back,
so none of them is left behind. Each operation uses a fresh context with autosave off.
Writes are serialized by a store-wide write lock held through the save, so concurrent edits get consecutive revision numbers. `pendingOutbox()` returns operations by intake, revision, then upsert before delete, then destination.
A disabled destination gets a `disabled` projection and no outbox operation.

## Usage constraints

The app must use ONE `SwiftDataJournalStore` per database file. The write lock is per instance, so two instances on the same file are unsupported and can assign duplicate revision numbers.

Delivery acknowledgement is not part of this store yet: there is no method to mark an outbox operation as delivered, so `pendingOutbox()` keeps returning queued operations. It arrives with the delivery-worker PR.

## Testing

Tests run on real on-disk stores in a unique temporary directory. A test flag makes the
next write fail after its inserts and before the commit.
