# Relay delivery

## What this is
`RelayDeliveryWorker` sends the journal's queued revisions to a HealthRelay receiver as intake-context
batches. It is the relay half of delivery: `HealthKitDeliveryWorker` (see `docs/healthkit-writer.md`) writes
the same revisions into HealthKit, and this worker sends them to the receiver, which holds the record of
what was eaten including the parts HealthKit has no quantity type for. The encoding is
`IntakeContextEncoder`; `docs/intake-context.md` is the contract mapping.

## Delivery is off
**Nothing in the app enables the relay destination, so nothing is ever queued for this worker and every
run finds an empty queue.** `AppServices` opens the journal store with `.healthKit` alone in a debug
build and with `enabledDestinations: []` in a release build, and neither includes `.relay`. The relay
therefore has a `disabled` projection and no outbox operation in any build, so there is nothing to send.
The worker exists and is tested against a fake transport; turning it on is a separate decision, made when
the HealthRelay connection ships, because it starts sending real intake data off the device.

Three things also stay off until then:

- **No transport.** `IntakeContextTransport` is a protocol with a fake in the tests and no implementation
  anywhere in this repository. The journal module holds no session, no URL and no HTTP client, and
  `URLSession` is not imported there at all.
- **No token.** The intake token is passed to `send(batch:token:)` per call. Nothing in the app has one:
  the token belongs to the connection, and rotating it is that connection's decision.
- **No link projections.** `RelayLinkProjectionQueueNone` is the default, so a worker built with nothing
  else sends upserts and deletes only.

## What one run does
`runOnce(now:)` walks `pendingOutbox()` in the store's own order — oldest revision first, so an edit is
sent after the revision it supersedes — and handles the operations addressed to `.relay`. Operations for
any other destination are left exactly as they are; a HealthKit operation is not this worker's business,
and acknowledging one would record another destination's delivery.

For each due relay operation the worker:

1. encodes it with `IntakeContextEncoder` — an `upsert` with the revision's facts and its link snapshot, or
   a `delete` as a tombstone standing one revision above the one it retracts;
2. packs the encoded operations into batches within the **receiver's own** `max_operations` and
   `max_body_bytes`, measured on the canonical bytes that would actually be sent;
3. sends each batch through the injected transport with the token, and maps what came back.

`now` is a parameter rather than a read of `Date()`, so a test and a replay after a restart see the same
decision about what is due and when a retry is scheduled.

## Ordering
The receiver applies a batch in array order and refuses an operation whose revision is below one it
already holds. So order is not tidiness here, it is the delivery succeeding.

**Whether an operation can be sent is decided in one place.** Each intake's queued operations are walked
once, in order, and the first thing that cannot go out ends the road for that intake: it is not due, it is
suspended, or it does not encode. That operation becomes the intake's blocker, and **every later operation
of the same intake is reported as blocked by it** — including one that would itself have encoded cleanly. A
sound revision offered after a broken one would come back `stale_revision`, because the receiver never
accepted the revision before it.

An **encoding failure is rescheduled, not parked**, because it is local and may be correctable: a link
snapshot naming a component the revision does not state is wrong once, not wrong forever, and parking it
would mean a correction could never be delivered. A conflict the *receiver* reports is different, and is
parked — see the outcome table.

Batches are then built only from the sendable prefixes, and each is filtered again before it goes. A
previous batch — or a split half of one — may have left an intake unresolved, and that intake's remaining
items are dropped from the rest of the run. **A 413 split obeys the same rule inside itself**: splitting is a
second request, not a second decision, so the tail is filtered through the head's results before it is sent.

### What stops the whole run
| From | Why |
|---|---|
| 401 | every later batch carries the same token to the same receiver, so one cause is reported rather than one refusal per batch |
| 429 | the receiver asked this producer to send less; the remaining batches are more of exactly that, and a split would not help since the limit is on traffic rather than size |

In both cases the operations already sent are reported as they were, and the ones the run never reached are
reported as `notAttempted` — untouched, with no attempt recorded against them.

### A deletion queued after a suspended upsert supersedes it
A suspension is normally the end of the road for an intake: nothing later for that intake goes past it, since
it was never delivered. **A deletion is the exception.** When a delete is queued behind a suspended upsert,
the upsert is resolved as superseded and reported as such, and the tombstone goes out.

The tombstone retracts exactly what the upsert would have put into the receiver, so the two say opposite
things about the same entry and only one can be right. The delete is what decides what the receiver holds —
that is already the rule for an upsert whose intake is gone — and holding it behind a suspension nothing
releases would mean the receiver kept an entry the person deleted, indefinitely, waiting on someone to
re-arm an operation that is no longer worth sending. Acknowledging the superseded upsert is what takes it out
of the queue and clears the suspension with it, so nothing is left parked afterwards.

**An acknowledgement that fails holds the intake back, and the delete with it.** Nothing was written, so the
upsert is still queued and still suspended, and the journal still claims an upsert is outstanding for that
intake. Sending the tombstone anyway would retract what the receiver holds while that claim stands, and the
ordering rule depends on the claim being true. The run reports the intake as blocked instead, and both rows
are left for the next one, when the write may succeed.

## Outcome mapping
One result per operation comes back in the 200, and the receiver's seven results map like this:

| Receiver result | Outcome | What the journal records |
|---|---|---|
| `accepted` | `delivered(operationID:acceptedRevision:serverCursor:)` | acknowledged; the projection becomes `succeeded` |
| `duplicate` | `delivered(...)`, same as `accepted` | acknowledged. A retry after a lost response is a duplicate, and the receiver holding the operation once or twice is the same state |
| `stale_revision` | `superseded(operationID:detail:)` | acknowledged. The receiver already holds a newer revision, so this operation is finished with |
| `domain_conflict` | `needsAttention(operationID:reason:)` | parked with the receiver's own reason; no retry until re-armed |
| `projection_conflict` | `needsAttention(...)` | parked, same as a domain conflict |
| `permanent_failure` | `needsAttention(...)` | parked. The payload itself is refused, so the same bytes are refused on every attempt |
| `retryable_failure` | `retryScheduled(operationID:nextAttemptAt:reason:)` | `attempts` grows and the operation is due again on the backoff |

A conflict and a permanent failure are parked rather than retried because no number of retries settles
them: both sides are durable records of the same facts. A scheduler that retried either would fail on a
timer forever and hide the disagreement behind a queue that never drains. The reason is **stored** with
the suspension and read back on every later run and after every relaunch, so a rejected token and a domain
conflict are never reported as the same thing.

**The accepted revision and the server cursor are reported, not written.** They are the receiver's own
stream position, and the journal's outbox records what it delivered and when. They belong to the
HealthRelay connection that will read them back.

## HTTP statuses
| Status | What happens |
|---|---|
| 200 | the per-operation results above |
| 400, 403 | permanent for the operations of that batch: the payload or the producer binding is refused, so the same bytes are refused again. The receiver's `error` code is the stored reason |
| 401 | **the run stops.** Retrying cannot mint a new token and every later batch would be refused the same way, so one cause is reported instead of one refusal per batch. The operations sent so far are parked with a token reason and no retry until re-armed; the operations the run never reached are reported as `notAttempted`. A 401 on the **head of a split** stops the split there too: the tail shares the refused credential, so sending it would be one more refusal for the same reason and would park those operations against a token already known to be bad |
| 413 | the batch is **split and each half retried, recursively**, keeping the order the operations were read in and filtering the tail through the head's results. How large one operation is on its own is not knowable here — one with a long link snapshot may need to travel alone while a bare facts-only one would have fitted — so only a **single** operation still refused is the payload being too large, and only that is parked. Parking whatever survived one halving would refuse operations that were perfectly sendable |
| 429 | **stops the run**, with or without `Retry-After`. A stated wait is honoured as given; without one, the **per-operation backoff ladder** decides, so a repeatedly throttled producer waits longer each time rather than holding at one minute |
| 5xx, and transport errors | retried on the backoff. A thrown transport error means nothing arrived, so there is no status to read and the same bytes are worth sending again |

The backoff is 1, 5 and 30 minutes, then every 2 hours, indexed by the attempt count **including** the
failure being handled. It is the same schedule `HealthKitDeliveryWorker` uses.

A 200 that does not name a result for an operation is reported as `notAcknowledged` and left pending: the
journal cannot say whether the receiver holds the operation, and reporting it as delivered would release
the revisions queued behind it. That is also what a failed acknowledgement produces.

## The batch limits
They come from `GET /v1/intake-context/capabilities` and nowhere else — `max_operations` and
`max_body_bytes` are the receiver's numbers, so a batch is packed against what it will actually take
rather than against a local guess that the first 413 would correct. The capabilities document is asked
for once per run, never once per batch.

**Those two routes are off by default on the receiver.** `GET /v1/intake-context/capabilities` and
`POST /v1/intake-context/batches` exist only when the receiver process was started with
`--enable-intake-context` (`health-bridge receiver start --db … --enable-intake-context`). Without the
flag it answers 404 on both, like any unknown path, and a receiver batch token offered at the intake
batch route gets 403 as well. So a first end-to-end test has to start the receiver with the flag before
anything on this page can be exercised, and a 404 on the capabilities read is that flag rather than a
wrong path or a version the receiver does not speak. The receiver's own `docs/architecture.md` and
`docs/reference/batch-v1.md` are the authority on this; the flag only enables the HTTP routes and does
not change mailbox delivery.

A capabilities read that fails sends nothing and reschedules every operation: a guess at the limits would
produce the very 413 this run exists to avoid.

**Both halves of the contract name are checked, and each has its own reason.** The `schema` must be
`healthrelay.intake-context` *and* the version must be one it lists. A receiver of some other contract may
well list a version this build also uses, and reading that as agreement would send intake data somewhere it
was never meant to go.

The two are reported differently because they are different problems: a receiver whose `schema` is not ours
is the **wrong endpoint**, while one that answers with our schema and does not list our version is the right
endpoint at a version this build does not speak. Either way the operations are parked rather than retried —
retrying cannot change what a receiver understands, and both are configuration facts a person settles rather
than failures of the operations themselves.

## What is injected, and why
| Injected | Why |
|---|---|
| `IntakeContextTransport` | the journal module holds no networking, and the delivery rules are tested against a fake rather than a receiver |
| the intake token, **asked once per batch** | a token is a credential the connection refreshes. Capturing one at initialization would leave every batch after a mid-run rotation carrying a value that had already expired, each refused 401 and each parking its work against a stale reason. A provider that cannot mint one reschedules the batch: nothing was sent, so nothing is parked |
| `IntakeContextEncoder` | the digests and the canonical bytes are the contract's, and the encoder is the only thing that computes them |
| `RelayLinkProjectionQueue` | a link projection has no outbox row, so the queue that offered it is told what became of it and owns where it waits |
| the link snapshot | the journal does not know which samples exist; that is the writer's knowledge. The default is no links, which the contract reads as "nothing linked yet" |
| the tombstone's `deleted_at` | the worker reads the instant the queued delete row recorded — what `delete(intakeID:now:)` was given, and the truthful answer to when the person deleted the entry |

## Two records the journal keeps so a retry is a retry
`deleted_at` and `healthkit_links` both sit inside the digests, and an operation's delivery identity never
changes, so **a retry is not a fresh encode**. The receiver reads the same `operation_id` with the same
`client_payload_hash` as a duplicate and with a different one as a conflict, which means anything that
varies between two attempts turns a lost response into a permanent disagreement:

- **The deletion instant** is written on the outbox delete row when that row is queued, and read back for
  every attempt. A row queued before the column existed carries none and falls back to the last revision's
  own instant, so an upgraded store does not strand a deletion it could otherwise deliver.
- **The sequence-1 link snapshot** is recorded with an upsert's first attempt, keeping the first one it is
  given, and reused on every retry. Links that arrived in between — a HealthKit save revealing a sample
  UUID — would move the projection and client digests, so a store that cannot record the snapshot cannot
  back this worker: it would have no way to make a retry the duplicate it needs to be.

  The snapshot is **encoded before it is recorded, and recorded immediately before the request that
  carries it goes out** — never after the answer, and never for a whole prepared batch at once. Recording
  first is what makes a retry a retry: a process death between the send and the write would otherwise leave a
  sent operation with nothing on record, and the next attempt would reuse the same `operation_id` with a
  different `client_payload_hash`, which the receiver reads as a permanent `domain_conflict` rather than the
  duplicate it should be. The store keeps the first snapshot it is given for the life of the operation, so an
  invalid one recorded eagerly would be frozen too: every later attempt would read the same bad links back and
  the encoder would refuse them again.

  **A record write that fails means the piece is not sent.** Putting a payload on the wire whose snapshot is
  not on record is the conflict above waiting to happen, and nothing has been sent, so the operation is
  rescheduled instead and a later item of the same intake is held back behind it — the receiver applies a
  batch in array order, so a later revision cannot go out past one that was never sent.

## An unattempted split tail keeps no frozen snapshot
A prepared batch is **not one request**. A 413 splits it, and each half is a request of its own that can fail
apart from the other: a 429 or a 401 on the head stops the split there, and an intake the head left unresolved
has its tail items filtered out of it. Those tail items were never on the wire, and **no link snapshot is left
on record for them**. A snapshot would freeze the links that happened to be current when the oversized batch
was packed, and so would go on missing every link that arrived while the tail waited.

A 413 applies none of its body, so nothing was committed under those delivery identities and there is nothing
for a later attempt to reproduce. The worker therefore **releases what the refused request recorded**, each
half records its own as it goes out, and an item whose half never goes out is left with nothing on record.

**Only a record this run wrote is released.** Recording reports whether it created the record, because a
snapshot already on record comes back identical to the one offered — whether it was left by an earlier attempt
whose answer may have been lost, or written by an overlapping run about to send it. Either way the receiver may
already hold that payload under the operation id, and discarding it would undo the very guarantee the record
exists for.

**A sole operation refused with 413 keeps its snapshot.** There is no split in that case: the payload was sent,
read, and refused for its size, and it is parked. A re-armed attempt has to repeat that same payload, so what
is on record is what it will send.

## What counts as a failed attempt
Only an operation that was eligible to send. When the capabilities read fails, an operation held back behind
a blocker is reported as `blocked` and left untouched — it was never going out regardless of the receiver,
so recording an attempt would advance its backoff for a failure it had no part in, and a queue that keeps
being blocked would drift to the two-hour step without anything ever having been tried.

Both are optional columns added by a lightweight migration, so no existing row is rewritten and nothing
already in a store is wrong after the upgrade.

## Link projections carry their own retry date
A projection has no outbox row, so `RelayLinkProjectionQueue` is told `retryAfter(_:reason:)` whenever one
is rescheduled, and is expected to honour that date when it offers projections again. Without it the queue
would hand the same projection back on the next run whatever the receiver said, and a run triggered for
unrelated work would retry it immediately — against a receiver that had just asked this producer to stop.
A projection that cannot be encoded at all is told `needsAttention` **and holds back the later projections
of the same intake**, which are later sequences of the same revision and would otherwise ask the receiver to
reconcile a state the earlier one could not be sent in.

## A superseded projection is reported as well as resolved
A projection naming an intake or a revision the journal no longer holds is resolved as `superseded` with its
queue, and the run **appends a `superseded` outcome** for it. The two halves are separate jobs and both
matter: the queue owns where the payload waits, so it has to be told the projection is finished with, and the
run's outcome list has to reconcile with the queue, so a caller reading the run learns what became of
everything it was offered. Resolving in the queue alone would leave an outcome list that silently drops
something the queue asked about.

## A projection of an older revision waits on the newer upsert
A queued projection for revision N of an intake, when an upsert for a newer revision of the same intake is
queued in the same run, is **neither sent before nor after it**. What settles it is whether the receiver
**accepted** that upsert — `accepted` or `duplicate` — which is the only thing that makes the older projection
obsolete:

| The newer upsert | The projection |
|---|---|
| accepted, or a duplicate | resolved as `superseded` and reported as such |
| superseded locally in this run — the intake is gone, so it left the queue unsent | resolved as `superseded` as well: nothing is queued under that id any more, so there is nothing to wait behind |
| never sent, or unresolved — a conflict, a permanent or retryable failure, an answer that could not be matched, or `notAttempted` | **stays queued**, and is reported as `blocked` by that upsert |

The reason is in what an upsert carries. **Every upsert carries a complete link snapshot for its own revision,
never a delta** — sequence 1 opens the projection lifecycle of that revision and the snapshot is whole. So
once the receiver *holds* the newer revision, the older projection has nothing left to say and would earn
`stale_revision`. But that is a fact about the receiver, not about the queue: an upsert merely being queued
says nothing about what the receiver holds. Resolving the projection on the strength of the upsert existing
would discard something still deliverable in every run where that upsert was refused or never went out, so the
decision waits for this run's answers and the projection waits with it. A locally superseded upsert is the
exception, and for the opposite reason: it is never coming, so waiting on it is waiting on nothing.

## Tests
`ios/NutritionCore/Tests/NutritionJournalTests/RelayDeliveryWorkerTests.swift` runs against a real
`SwiftDataJournalStore` on disk and a fake transport that reads the `operation_id`s out of the bytes it was
handed, so an assertion is about what was actually encoded rather than about what the test expected. It
covers every row of the outcome table, 429 with and without `Retry-After` and the ladder a headerless one
walks, both of them stopping the run, 401 stopping the run and the next run not retrying, a stop on the head
of a split, 400, 403, 5xx and transport errors, a token that cannot be read and one fetched per batch, a 413
split that recurses until only a single operation is refused, both batch limits, the order of one intake's
revisions, a parked *later* revision not stranding an earlier due one, an earlier failure blocking a sound
revision behind it, a suspended operation holding back what is behind it, a split tail held back for an
intake the head left unresolved, a delete sent as a tombstone with the instant the journal recorded, an upsert
retry reusing its first link snapshot, an invalid first snapshot not frozen and a corrected one delivered, a
projection's retry date reaching its queue, an unencodable projection holding back the later ones, a
superseded projection reported as well as resolved, a projection of an older revision superseded only once the
newer upsert is accepted and blocked by that upsert when it is not, a projection settled too when that upsert
is superseded locally, a delete queued after a suspended upsert superseding it and still going out, a held-back
delete when that acknowledgement fails, an unattempted split tail keeping no frozen snapshot so the links that
arrived while it waited go out with it, a snapshot on record before the request carrying it and before each
split piece, a failed record write sending nothing, a 413 leaving another run's snapshot alone, and a sole
operation refused for size keeping the snapshot it was sent, and delivery off — a store with no enabled relay
destination sends nothing at all, and does not even ask the receiver for its capabilities.

Swift tests run in macOS CI; the acceptance for this package is static.