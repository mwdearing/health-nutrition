# HealthKit writer: the plan and the delivery worker

Two halves, in two layers. The **plan** (`HealthKitWritePlanner`) is pure data: which samples a
revision would write. The **delivery worker** (`HealthKitDeliveryWorker`) walks the journal's queue,
asks the app target to carry the plan out, and records what happened. Neither half imports HealthKit;
only the app target's `HealthKitSampleWriter` does.

## What it is
The pure half of the HealthKit writer (NC-07). `HealthKitWritePlanner` in
`ios/NutritionCore/Sources/NutritionJournal/HealthKitWritePlan.swift` answers one question: given a
journal revision and its nutrient totals, which HealthKit samples would be written, and with which
sync metadata? It answers it as plain data. `NutritionJournal` may not import HealthKit —
`scripts/lint_swift_sources.py` forbids `import HealthKit` in that layer, and the rule exists so the
journal stays testable on macOS — so the quantity type is named by its identifier **string**
(`"HKQuantityTypeIdentifierDietaryWater"`) and the app target looks the type up and builds the
`HKQuantitySample` later. Nothing in this module authorizes, saves, queries or deletes anything.

The behaviour follows [ADR 0002](../adr/0002-healthkit-sync.md), which records what HealthKit actually
did on a device rather than what its documentation says. The three consequences that shape this
plan:

- **One sync identifier per (intake, nutrient)**, `"intake:<intakeID>:<nutrientKey>"` — for example
  `intake:e6677963-418c-4027-b563-551d8a531eed:water`. A shared identifier
  would let two nutrients of one intake resolve against each other; the spike in ADR 0002 gave water
  and protein separate identifiers for exactly this reason. The `intake:<id>:<key>` shape is not a
  free choice here: it is the convention the HealthRelay intake-context v1 receiver contract and its
  golden vectors write, so it matches that contract's worked example and the writer and the receiver
  end up naming the same sample.
- **The sync version is the journal revision.** A higher version replaces the sample; an equal
  version replaces it again (harmless, because the sample is rebuilt entirely from the stored
  revision); a lower version is silently ignored and still reports success, so the writer never
  treats a successful save as proof that the store now holds this revision.
- **Timestamps come from the intake.** `start` and `end` are both `occurredAt`, the intake's own
  time. Nothing here reads `Date()`: a retry has to rebuild identical metadata, or an equal-version
  replacement would write a different sample than the one it replaces.

## The mapping table
`HealthKitWritePlanner.mappings` is the whole table. The units are the ones HealthKit accepts for
these types, and every total is converted into them with `MeasureUnit` before a spec is built, so
the planner never does arithmetic of its own: `Decimal` throughout, exact powers of ten only.

Every identifier is one of HealthKit's dietary quantity types, **prefix included**: HealthKit spells
the minerals and the vitamins with the same `Dietary` prefix as the macronutrients
(`HKQuantityTypeIdentifierDietarySodium`, `HKQuantityTypeIdentifierDietaryIron`,
`HKQuantityTypeIdentifierDietaryVitaminD`), so an identifier without it would not resolve to a type
and the app target could neither authorize nor build a sample for it. A test asserts that every
identifier in the table starts with `HKQuantityTypeIdentifierDietary`.

| Nutrient key | Also stored as | HealthKit identifier | HealthKit unit |
|---|---|---|---|
| `water` | | `HKQuantityTypeIdentifierDietaryWater` | `mL` |
| `energy` | `energyKcal` | `HKQuantityTypeIdentifierDietaryEnergyConsumed` | `kcal` |
| `protein` | | `HKQuantityTypeIdentifierDietaryProtein` | `g` |
| `carbohydrate` | `carbohydrates` | `HKQuantityTypeIdentifierDietaryCarbohydrates` | `g` |
| `fat` | | `HKQuantityTypeIdentifierDietaryFatTotal` | `g` |
| `fiber` | | `HKQuantityTypeIdentifierDietaryFiber` | `g` |
| `sugar` | `sugars` | `HKQuantityTypeIdentifierDietarySugar` | `g` |
| `sodium` | | `HKQuantityTypeIdentifierDietarySodium` | `mg` |
| `potassium` | | `HKQuantityTypeIdentifierDietaryPotassium` | `mg` |
| `calcium` | | `HKQuantityTypeIdentifierDietaryCalcium` | `mg` |
| `magnesium` | | `HKQuantityTypeIdentifierDietaryMagnesium` | `mg` |
| `iron` | | `HKQuantityTypeIdentifierDietaryIron` | `mg` |
| `zinc` | | `HKQuantityTypeIdentifierDietaryZinc` | `mg` |
| `caffeine` | | `HKQuantityTypeIdentifierDietaryCaffeine` | `mg` |
| `vitaminD` | | `HKQuantityTypeIdentifierDietaryVitaminD` | `mcg` |
| `vitaminB12` | | `HKQuantityTypeIdentifierDietaryVitaminB12` | `mcg` |
| `folate` | | `HKQuantityTypeIdentifierDietaryFolate` | `mcg` |

### The keys the journal really stores
The leftmost key is the **canonical** one: it names the row in `plan`'s output order and it is what
goes into the sync identifier, so a nutrient keeps the same HealthKit sample however the journal
spelled it. The "also stored as" column holds the **aliases**.

The journal does not store one vocabulary. A barcode-backed entry keeps the keys its source uses
verbatim — `LookedUpProduct.standardKeys` and `AddIntakeViewModel.productSnapshot()` write
`energyKcal`, `carbohydrates` and `sugars`, alongside `protein`, `fat`, `fiber`, `sodium`,
`saturatedFat` and `salt` — while hand-entered and recipe totals use the singular canonical names.
Reading only the canonical names meant an entry's energy, carbohydrate and sugar values were treated
as unmapped and never reached HealthKit, so each row also accepts its aliases.

A row resolves its keys in order and takes the first one that is `.known` and converts exactly into
the row's unit:

- a canonical key and its alias both present produce **one** sample, under the canonical key, with
  the canonical value. Two samples for one nutrient would both write to the same HealthKit type and
  the same sync identifier, and which one survives would depend on save order.
- an alias stands in when the canonical key is `.unknown`, `.notApplicable` or
  `.belowReportingThreshold`, which is what a snapshot that recorded only `energyKcal` looks like.

`saturatedFat` and `salt` have no row: HealthKit has no plain "total sugars"-style counterpart that
this table promises, and saturated fat is not part of what the journal totals today, so both are
skipped as unmapped. A key no row maps keeps its own identity in a deletion, so it is never silently
folded into another nutrient.

Conversion is exact: 1500 mg of protein plans as 1.5 g, 1500 mcg of sodium as 1.5 mg, 1 mg of
vitamin D as 1000 mcg, 0.25 L of water as 250 mL. Kilojoules are not a `MeasureUnit` in this
project, so an energy total has to reach the planner already in `kcal`; the planner has no
kilojoule factor to apply and would skip a total it cannot convert.

## What the plan does not write
A total that is `.unknown`, `.notApplicable` or `.belowReportingThreshold` is skipped, and so is:

- a nutrient key with no mapping in the table,
- an international-unit total (IU never converts, and HealthKit has no IU dietary unit),
- a total whose unit cannot be converted to the mapped unit, such as energy in grams.

Skipping means *no sample at all*, never a sample of zero: the journal reads an absent nutrient as
unknown, and writing 0 would turn "not stated" into "none" in the Health app. A nutrient that is
genuinely `.known(0)` is a label statement and is written as zero.

Water is not special-cased: the `water` total is the millilitres of the intake's volume component,
which the caller passes in like any other total.

## Determinism
`plan(intakeID:revision:occurredAt:totals:)` returns the specs sorted by nutrient key, so the same
totals always plan the same order no matter how the totals dictionary was built.

## Deletion
`deletion(intakeID:keys:)` returns the sync identifiers to remove, sorted and deduplicated. Per ADR
0002 the journal keys nothing off a HealthKit UUID — UUIDs change on every accepted save — and a
delete goes by sync identifier **and** this app's own source, so a sample another app wrote is never
touched. `HealthKitSampleSpec` deliberately carries no UUID field for the same reason.

**A delete covers every key the caller passes, not only the ones this revision writes.** A later
revision can drop a nutrient: the plan then produces no sample for it (an unknown total is skipped,
never written as zero), so nothing would replace the sample an earlier revision wrote and Health would
keep showing a stale value. Deleting the stale sample and then writing the current revision is the
only way to retract it, which is why the identifiers are a superset of the ones `plan` returns for the
same keys. Which keys a delete covers is the caller's decision — the journal knows what a revision
recorded — so the planner lists every key it is given. An alias is resolved to its canonical key
first, so a caller that names a nutrient the way a snapshot stored it still deletes the sample that
was written.

## The delivery worker

`HealthKitDeliveryWorker` in
`ios/NutritionCore/Sources/NutritionJournal/HealthKitDeliveryWorker.swift` is the other half. One
`runOnce(now:)` walks `pendingOutbox()` in the store's own order — oldest revision first, upsert
before delete within a revision — and handles only the operations addressed to `.healthKit`.
**Operations for any other destination are left untouched**: a relay operation is not this worker's
to deliver, and acknowledging one would record another destination's delivery as done.

`now` is a parameter rather than a read of `Date()`, because it decides two things that must be
predictable: whether an operation is due, and when a retry is scheduled.

### What an upsert does

1. **Totals.** The totals for `(intakeID, revision)` come from an injected `NutrientTotalsProvider`,
   which **throws** when it cannot read the revision. This matters: the worker treats empty totals as
   "this revision states no nutrient", which would delete everything the earlier revisions wrote as
   stale, save nothing and acknowledge the operation. A failed read must never become a successful
   empty revision, so the failure has to reach the worker and leave the operation pending.

   `JournalSnapshotTotals` is the default, and it states very little on purpose. A product snapshot's
   nutrients are stated on `labelBasis` (typically per 100 g), **not** for the amount the component
   records: a 40 g portion of a product whose label states 13 g of protein per 100 g carries 5.2 g.
   Scaling needs to know the basis exactly — a serving, a yield and a count all scale differently — so
   until that arithmetic exists **no snapshot nutrient is emitted**, rather than an unscaled one. The
   planner then plans no sample for it, which is the honest outcome. Water is the one value it does
   report: a **water-category** intake's volume components, because volume is dietary water when the
   entry is a drink. 250 mL of milk, juice or oil is not, and is not counted.
2. **Plan.** `HealthKitWritePlanner.plan(intakeID:revision:occurredAt:totals:)` turns them into
   `[HealthKitSampleSpec]`, ordered by nutrient key, stamped with the intake's own `occurredAt`.
3. **Stale deletion.** For any revision after the first, the samples for mapped nutrients **this plan
   does not write** are deleted first, then the plan is saved. The order matters: an edit can drop a
   nutrient, an unknown total plans no sample, so nothing would replace what an earlier revision left
   and Health would keep showing it. Revision 1 deletes nothing — nothing has been written yet.
4. **Save**, then **acknowledge**. The acknowledgement stamps `acknowledgedAt` and moves the
   projection to `succeeded`, so `pendingOutbox()` stops offering the operation.

### Revisions are delivered in order, per intake

**A later operation for an intake waits behind an unresolved earlier one.** Revisions are delivered
oldest first, and an operation that is not due, that failed, or that is waiting for a person holds up
everything after it for the same intake; those later operations report `.blocked`.

Writing them out of order is not a cosmetic problem. If revision 2 is saved while revision 1 is still
waiting, and revision 2 dropped a nutrient, then no higher-version sample protects that nutrient. When
revision 1 is finally delivered, HealthKit accepts its obsolete sample — ADR 0002's run showed a lower
version is **silently ignored but still accepted as a save** — and stale nutrition data reappears.

**A failed acknowledgement is unresolved too.** If the samples reach HealthKit but the store cannot
record the delivery, the operation is still queued, so the outcome is `.notAcknowledged` rather than
delivered. Letting the run continue to a newer revision would set up exactly the same failure on the
next run, which would redeliver the older revision into a queue where its stale-sample deletion has
already removed the protection.

### Retraction is per type

A delete asks about **every** mapped type, because any of them may hold a sample this app wrote. It
still removes everything it is authorized to remove: someone can authorize water and refuse protein,
and aborting the whole retraction would strand the authorized water sample in Health after the journal
entry is gone — a sample the app could never remove again, attached to an entry that no longer exists.

So the retraction deletes what it may and reports `.partlyRetracted`, naming the denied type
identifiers. Only those keep the operation queued and the projection at `needsAttention`.

### A projection update matches the operation's action

Deleting an intake does **not** bump its revision, so a queued upsert and a queued delete for that
intake share an intake id, a revision number and a destination, and differ only by action. The store
therefore matches the projection on **intake, revision, destination and action**: without the action,
acknowledging the stale upsert marks the delete `succeeded`, and the app reports a finished retraction
while the samples are still in Health.

### What a delete does

Every mapped key for the intake is deleted, whether or not the current revision ever wrote it, because
an earlier revision may have. The operation is acknowledged when the deletion returns. A delivered
delete also marks any still-queued upsert for that intake **superseded**: its samples were just
retracted, so writing it would put back exactly what was removed.

### Authorization

Write access is asked per quantity type (`canWrite(identifiers:)`) before anything is written, not
after a save fails. ADR 0002's run showed the permission sheet under-reports what it granted, so
`HKHealthStore.authorizationStatus(for:)` is the answer the writer trusts. A type that is not
authorized produces the same typed `HealthSampleWriterError.authorizationDenied` a failed save would,
so both routes end in the same place.

## Retry policy

| Failure | What happens |
|---|---|
| `authorizationDenied` | Projection becomes `needsAttention`, the operation is **suspended**, no retry is scheduled. |
| `HealthSampleRejectedError` (an invalid sample) | Same: the operation is **suspended** with HealthKit's reason. |
| `HealthSampleWriterError.transient` | `attempts` grows by one, `nextAttemptAt` moves out along the backoff. |
| Any other error, including a failed totals read | Treated as transient: retrying is the safe direction. |
| The store's acknowledgement throws after a successful write | Reported as `.notAcknowledged`, which is **unresolved**. |

A denial is never retried because **retrying cannot grant Health access**. A worker that retried it
would fail on a timer forever and hide the real problem behind a queue that never drains; leaving the
projection in `needsAttention` puts it in front of a person instead.

### An invalid sample is permanent, not transient

`HKError.errorInvalidArgument` is the other failure waiting cannot fix, and it used to fall through to
the transient branch, so it backed off on the 1/5/30-minute-then-2-hours schedule **forever**. Apple's
[save contract](https://developer.apple.com/documentation/healthkit/hkhealthstore/save%28_%3Awithcompletion%3A%29-47iwb)
counts an invalid argument as a save failure, and the app target cannot argue with it: a retry rebuilds
the same `HKQuantitySample` from the same immutable journal revision, down to the sync version, so the
identical sample is rejected identically every time. The writer therefore raises
`HealthSampleRejectedError` for that code alone, and the worker marks the operation `needsAttention`
with HealthKit's reason rather than scheduling a retry that cannot succeed — the entry, or the plan
built from it, has to change first, and that is a person's decision.

This is deliberately narrow. A **unit symbol the writer does not recognise** is still transient, because
it means the writer's table and the planner's disagree, which a later build may well fix; only an
invalid argument from HealthKit itself, about a sample this app built itself, is permanent.

Suspension has to be **explicit state**, not the absence of a retry date. A denied operation records
`nextAttemptAt == nil`, which reads identically to "due now" — the very first attempt also has no date
— so a run that inferred it from the operation would retry the denied write on every pass and grow its
attempt count forever. The worker therefore asks the store which operations are suspended
(`suspendedOperationIDs()`), which reads the projections, and leaves those alone. **Re-arming is a
deliberate act**: `rearmDelivery(operationID:)` clears the suspension and makes the operation due
again, and only a person decides when a denial has actually been resolved.

**A suspension belongs to the operation, not to the current projection.** An edit supersedes the earlier
projections while leaving their operations pending, so a denied revision 1 whose projection has just
gone noncurrent is still an undelivered, suspended operation. `suspendedOperationIDs()` therefore matches
each `needsAttention` projection to its operation whatever its currency; filtering on `isCurrent` would
drop the suspension, retry the denied write forever and block the newer revision indefinitely.

Both halves of a suspension have to reach that projection, superseded or not, and this includes the
moment the suspension is **recorded**. An edit queued *before* the revision's first delivery attempt
has already superseded its projection, so a denial arriving afterwards found only current projections to
mark: nothing became `needsAttention`, the operation looked due, and every automatic run retried it
and grew its attempt count. `recordFailure` therefore writes `needsAttention` to the operation's own
projection whatever its currency, and `rearmDelivery` clears it from the same place. Every other
projection update — an acknowledgement, a transient failure — deliberately touches current projections
only.

The backoff is **1, 5 and 30 minutes, then every 2 hours**
(`HealthKitDeliveryWorker.backoffSeconds(afterAttempt:)`). Backoff rather than a fixed interval: one
failure is usually a store error, while a failure that never clears is a device that is asleep or out of
battery, where an hourly retry costs nothing. The schedule is indexed by the failure **being handled**
— the count including the one in progress, which `recordFailure` has not written yet — so the first
failure waits a minute, the second five, and the wait never shrinks.

A failed delivery **stays in the queue**. Only a recorded success is removed from it, because a
delivery that was not recorded must not be forgotten. An operation whose `nextAttemptAt` is still in
the future is skipped and reported as `.notDue`.

A retry rebuilds the plan from the stored revision, so it is byte-identical to the first attempt: an
equal-version replacement, which ADR 0002's run showed HealthKit accepts and which changes nothing.

## Delivery is off until it is turned on

`AppServices` constructs the worker, but `SwiftDataJournalStore` is opened with
`enabledDestinations: []`. **No HealthKit operation is ever queued, so `runOnce` always finds an empty
queue and the app writes nothing to Health.** Turning delivery on means changing that one setting, and
it is a separate decision because it starts writing real intake data into a user's health store —
scaling the totals first, and asking the user, are both still open. Nothing in this task changes it.

The journal store keeps the `disabled` projection for HealthKit, so entries do not sit in a permanent
`pending` state while delivery is off.

## Tests
`ios/NutritionCore/Tests/NutritionJournalTests/HealthKitWritePlanTests.swift` covers the identifier
and version shape, the dietary prefix on every identifier, the journal's stored vocabulary and its
aliases, every skip case, the exact conversions, water, the deterministic order, the timestamps and
the deletion identifiers.

`ios/NutritionCore/Tests/NutritionJournalTests/HealthKitDeliveryWorkerTests.swift` covers the worker
against a real on-disk store and a fake writer: an upsert writes the plan and acknowledges, an edit
deletes the stale nutrient before saving, a delete removes every mapped identifier, a denied type goes
to `needsAttention` without a retry, a transient failure is rescheduled on the backoff and grows
across attempts, an operation that is not due is skipped, another destination's operations are left
alone, an acknowledged operation is not delivered again, and a retry rebuilds the same specs. It also
covers the cases above that are easy to get wrong: a newer revision is **blocked** behind an unresolved
earlier one (not due, and failed-and-retrying), a failed totals read leaves the operation pending
instead of writing an empty revision, unscaled snapshot nutrients are omitted, a suspended operation
is skipped by later runs and returns after being re-armed, repeated failures follow 1/5/30 minutes, a
retraction removes the authorized types while naming the denied ones, volume only counts as water for
a water-category intake, and acknowledging a stale upsert does not mark the delete projection
`succeeded`. It also covers the two retry edge cases: a denial recorded on a projection an earlier edit
had already superseded still suspends the operation, and a sample HealthKit rejects as invalid goes to
`needsAttention` instead of being retried. `swift test` runs on macOS in CI; the values are synthetic.