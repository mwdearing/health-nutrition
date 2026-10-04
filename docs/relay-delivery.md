# Relay delivery

## What this is
`RelayDeliveryWorker` sends the journal's queued revisions to a HealthRelay receiver as intake-context
batches. It is the relay half of delivery: `HealthKitDeliveryWorker` (see `docs/healthkit-writer.md`) writes
the same revisions into HealthKit, and this worker sends them to the receiver, which holds the record of
what was eaten including the parts HealthKit has no quantity type for. The encoding is
`IntakeContextEncoder`; `docs/intake-context.md` is the contract mapping.

## Delivery is off
**Nothing in the app enables the relay destination, so nothing is ever queued for this worker and every
run finds an empty queue.** `AppServices` opens the journal store with `enabledDestinations: []`, which
gives the relay a `disabled` projection and no outbox operation, so there is nothing to send. The worker
exists and is tested against a fake transport; turning it on is a separate decision, made when the
HealthRelay connection ships, because it starts sending real intake data off the device.

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
already holds. So order is not tidiness here, it is the delivery succeeding:

- operations are read in queue order and packed in that order, so one intake's revisions travel oldest
  first, in one array when they fit;
- an operation that is **suspended** or **not due yet** holds back every later operation for the same
  intake, because it was never delivered;
- once a batch comes back, an operation whose outcome is unresolved holds back the later operations for
  its intake in the batches after it.

A queued upsert whose intake has since been deleted is acknowledged as **superseded**, not sent: the
delete queued beside it is what decides what the receiver holds, and sending the upsert would put back
exactly what that delete retracts.

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
| 401 | **the run stops.** Retrying cannot mint a new token and every later batch would be refused the same way, so one cause is reported instead of one refusal per batch. The operations sent so far are parked with a token reason and no retry until re-armed; the operations the run never reached are reported as `notAttempted` |
| 413 | the batch is **split once** and each half is retried, keeping the order the operations were read in. An operation too large on its own cannot be split, so it is parked as permanently refused |
| 429 | retried at `Retry-After` when the receiver sent one — a rate limit answered with its own interval is the receiver telling this producer exactly how long to stop — and on the backoff when it did not |
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

A capabilities read that fails sends nothing and reschedules every operation: a guess at the limits would
produce the very 413 this run exists to avoid. A receiver that does not list this build's schema version
has its operations parked rather than sent, because such a receiver refuses the batch while parsing it,
which would look like a permanent failure of every operation rather than of the version.

## What is injected, and why
| Injected | Why |
|---|---|
| `IntakeContextTransport` | the journal module holds no networking, and the delivery rules are tested against a fake rather than a receiver |
| the intake token, per call | rotating it is the connection's decision, and two batches in one run may carry different tokens |
| `IntakeContextEncoder` | the digests and the canonical bytes are the contract's, and the encoder is the only thing that computes them |
| `RelayLinkProjectionQueue` | a link projection has no outbox row, so the queue that offered it is told what became of it and owns where it waits |
| the link snapshot | the journal does not know which samples exist; that is the writer's knowledge. The default is no links, which the contract reads as "nothing linked yet" |
| the tombstone's `deleted_at` | it is hashed into two digests, so a rebuilt delete has to carry the same instant or the receiver reports a conflict instead of the duplicate it is. The journal records no deletion instant, so the default anchors it to the `createdAt` of the revision the delete retracts: durable, immutable and identical on every rebuild |

## Tests
`ios/NutritionCore/Tests/NutritionJournalTests/RelayDeliveryWorkerTests.swift` runs against a real
`SwiftDataJournalStore` on disk and a fake transport that reads the `operation_id`s out of the bytes it was
handed, so an assertion is about what was actually encoded rather than about what the test expected. It
covers every row of the outcome table, 429 with and without `Retry-After`, 401 stopping the run and the
next run not retrying, 400, 403, 5xx and transport errors, the 413 split and a 413 that cannot be split,
both batch limits, the order of one intake's revisions, a suspended operation holding back what is behind
it, a delete sent as a tombstone, and delivery off — a store with no enabled relay destination sends
nothing at all, and does not even ask the receiver for its capabilities.

Swift tests run in macOS CI; the acceptance for this package is static.