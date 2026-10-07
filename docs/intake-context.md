# Intake context

## What the app sends
Intake context is the record of what a person ate or drank, including the components HealthKit has no
quantity type for: a creatine supplement stirred into water, or a proprietary blend whose members the label
does not disclose. It travels to the HealthRelay receiver as one batch of operations, each an `upsert`, a
`delete` or a `link_projection`, and it never impersonates an `apple_health.*` source in the measurement API.

The contract is the receiver's, and this repository keeps a copy of it:
- `contracts/intake-context/healthrelay.intake-context.v1.schema.json` - JSON Schema, draft 2020-12.
- `contracts/intake-context/README.md` - **the full specification**: batch shape, operations, facts, links,
  the revision and projection lifecycle, canonical JSON, the three digest scopes and the worked values.
- `contracts/intake-context/fixtures/valid_*.json` - four valid synthetic batches. Every UUID, bundle id and
  sample in them is synthetic test data.

That README is the source of truth. Nothing in this app may relax one of its rules, because the receiver
recomputes every digest from the operation it received and rejects an operation whose digest does not match.

## What this module implements
- `IntakeContextJSONValue` is the payload as a JSON value with no binary floating point in it. Every amount is
  a decimal string, and only `revision`, `projection_sequence` and `sync_version` are integers, which keeps the
  literal spelling as the content: `"5"` and `"5.0"` are different facts.
- `IntakeContextJSONReader` reads that payload. `JSONSerialization` is not used, because it hands numbers over
  in a binary floating point type and would rewrite a number's spelling before a digest is taken, and because
  the contract rejects documents it accepts: a duplicate object name, a number with a decimal point or an
  exponent, and an unpaired surrogate escape.
- `IntakeContextCanonicalJSON.encode(_:)` writes the contract's canonical bytes: keys sorted by Unicode code
  point at every depth, no whitespace, raw UTF-8 for everything that is not a required escape, `\u00xx` with
  lowercase hex for the remaining control characters, plain decimal integers and lowercase literals.
- `IntakeContextDigests` computes `domainFactsHash(batch:operation:)`, `projectionHash(batch:operation:)` and
  `clientPayloadHash(batch:operation:)`. Each returns `sha256:` followed by 64 lowercase hexadecimal
  characters of the canonical bytes of its scope, computed with SHA-256 from CryptoKit.
- `IntakeContextEncoder` encodes a journal revision as one contract operation, and `IntakeContextFactCatalog`
  maps a journal component to the contract concept it stands for. `IntakeContextTimestamp` writes the two
  timestamp forms the contract asks for.

## The journal to operation mapping
`IntakeContextEncoder` is constructed with the producer scope (`producer_id`, `writer_bundle_id`,
`installation_id`), and that scope is the only source of those three batch fields. It has no clock and no
randomness: the same revision encoded twice produces the same bytes, which is what makes a retry a duplicate
rather than a conflict.

| Contract field | Journal source | Rule |
|---|---|---|
| `schema`, `schema_version` | `IntakeContextEncoder.schema`, `.schemaVersion` | Constant `healthrelay.intake-context`, `1.0`. No digest covers the constant, but every digest covers `schema_version`. |
| `batch_id` | the caller's delivery id, `batch(batchID:operations:)` | Transport only; no digest covers it, so a retry may reuse it. It is normalized to lowercase canonical UUID text, and text that is not a UUID is refused. |
| `producer_id`, `writer_bundle_id`, `installation_id` | the injected `IntakeContextProducerScope` | Inside `client_payload_hash`; `producer_id` is also inside the other two, so the same intake id from another producer never collides. All three are checked against the schema before anything is hashed: `producer_id` is a slug, `writer_bundle_id` matches the contract's bundle-identifier pattern and `installation_id` is normalized to lowercase canonical UUID text when the scope is built, because the schema requires that form and `UUID().uuidString` is upper case. A configuration mistake is a local refusal, not a permanent failure after a delivery. |
| `operations` | `upsert(...)`, `delete(...)`, `linkProjection(...)` | Array order is the receiver's apply order, so the caller's order is kept. Every input must be a single operation encoded under this encoder's scope: a value that is already a batch carries its own envelope and would nest one inside `operations`, so it is refused. |
| `operation_id` | `OutboxOperation.operationID`, or `linkProjectionOperationID(intakeID:sequence:)` for a link projection | The delivery identity: the same id with the same `client_payload_hash` is a duplicate, and with a different one a conflict. For an upsert or a delete it is the outbox row's id, and that row's destination must be `.relay` and its action the one the method delivers, so a worker that picks up the wrong pending row cannot send one kind of operation under another's delivery identity. A **link projection takes no outbox row**: sequence 1 was already delivered under the revision's relay upsert row, and reusing that id with different links is a conflict rather than an update, so every sequence has an identity of its own - the caller's when it has queued a row for that delivery, and otherwise one derived from the intake, the revision and the sequence, which is stable across retries because the contract reads a repeated payload under one id as a duplicate. The revision is in that seed because a sequence restarts at 2 for every revision: sequence 2 of revision 3 and sequence 2 of revision 4 are different deliveries. |
| `operation` | `OutboxOperation.kind`, or `linkProjection(...)` | `upsert`, `delete` or `link_projection`. |
| `intake_id` | `Intake.id` | Lowercase UUID. An operation whose outbox row names another intake or another revision is refused. |
| `revision` | `IntakeRevision.number` | Monotonic per intake. A delete is written at **one above** the revision it deletes, because the contract requires a tombstone to stand above every accepted revision; the outbox row is the journal's bookkeeping at the last accepted revision and is not the revision the tombstone claims. |
| `projection_sequence` | 1 for an upsert, the caller's sequence for a link projection | An upsert opens the projection lifecycle of its revision, so it is always 1; a link-only change starts at 2 and carries the complete snapshot. |
| `occurred_at` | `IntakeRevision.occurredAt ?? Intake.occurredAt` | Read off the revision being sent, not the entry's current row: both members are hashed into all three digests, so a revision rebuilt after a correction of the entry's time from the entry's values would arrive under the same `operation_id` with a different payload — a conflict rather than the duplicate it is. Written in the zone below with that zone's offset at the instant, so the wall clock and the instant agree. |
| `time_zone` | `IntakeRevision.timeZoneIdentifier ?? Intake.timeZoneIdentifier` | An IANA name, never a host-local key. A name this platform does not know is refused, and so is one it knows but the contract does not accept: `Factory`, `localtime`, `posixrules` and the `posix/` and `right/` copies, because they name one zone on this device rather than on every receiver. |
| `recorded_at` | `IntakeRevision.createdAt` | An instant rather than a wall clock, so it is written in UTC. |
| `deleted_at` | `IntakeContextTombstone.deletedAt` | The instant from the **persisted** tombstone, not a fresh reading of the clock: it is hashed into both the domain and the client digest, so a delete rebuilt after a lost response has to carry the same instant or the receiver reports a conflict instead of a duplicate. A tombstone that names another intake is refused. |
| `category` | `Intake.category` | The journal's slug. |
| which product the facts come from | the `ProductDefinition?` passed to `upsert` | It must be the snapshot `revision.productSnapshotID` names, and a revision that names none must be encoded with no product at all. The product's name and nutrient states are hashed as immutable facts of `(intake_id, revision)`, so another snapshot would silently make this revision's facts that product's values and the receiver would reject the retry as a domain conflict. |
| `display_name` | `ProductDefinition.name`, else `Intake.meal`, else `Intake.note`, else `Intake.category` | The first non-empty of those. |
| `serving` | the revision's components | The first component measured by volume, else the first measured by count, else the first component. The journal has no serving of its own. |
| `facts` | the revision's components, then the product snapshot's nutrients | One fact per component in component order, which is part of the hashed content, followed by one fact per nutrient the snapshot states. A barcode or recipe entry keeps a single food component and puts its nutrition in the snapshot, so the components alone would send an invented fact for the food and none of the values behind it; each stated nutrient becomes a fact under its own code, which is also what lets a link to it join. |
| the snapshot values' scale | `labelBasis` and the logged components | A snapshot states the product, not the portion: 40 g logged of a product stated as 13 g of protein per 100 g carries **5.2 g**, and sending 13 g would state the whole package. `IntakeContextSnapshotBasis` reads the basis the snapshot names - per 100 g, per 100 mL, per serving, per scoop, per tablet or per capsule - and scales by the logged quantity in that unit. A basis it cannot resolve - "per 100 g or mL", "per 100 kcal", anything unknown - sends **nothing** rather than something unscaled, which is why `JournalSnapshotTotals` states no snapshot nutrient for such a product either. |
| the fact's code | the snapshot's nutrient key | The fact's identity is the canonical slug (`energy`), but its **code** is the catalog code for that nutrient: `dietary_energy_consumed`, which is what `HKQuantityTypeIdentifierDietaryEnergyConsumed` follows from and what the contract's own blend fixture writes. A fact coded `dietary_energy` would name a type HealthKit does not have. | 
| one fact per nutrient | the snapshot's keys, canonicalized | A canonical key and an accepted alias name one nutrient (`energy` and `energyKcal`), so they produce **one** fact: the first key in sorted order speaks for it, and every id written is tracked so `component_id` stays unique as the contract requires. |
| `facts[].component_id` | `IntakeComponent.componentID` | Any slug the contract accepts, unique within the operation; a repeated one and an id outside `^[a-z0-9][a-z0-9._-]{0,63}$` are refused. The journal builds these ids from food names and from recipes, so they are not a fixed list. |
| `facts[].kind`, `.code`, `.aggregation_role`, `.quantity_basis`, `.provenance` | the component, its product, and `IntakeContextFactCatalog` as the overrides | The kind fixes the role: a nutrient is `context_only`, a compound is `compound_measurement` and needs a basis, a blend is `blend_total_only` and needs members. A compound states `quantity_basis` and so does a blend, whose total is a mass of the blend as printed; a nutrient states none, because its amount is the nutrient's own. A component with a catalog row is that row. Any other slug is inferred: it is a nutrient, because a compound and a blend carry facts a journal component does not have; its code follows what it measures (a volume is water, so `hydration`, and anything else is `dietary_<its own name>`, which is also what lets a link to it join, kept inside the schema's 64-character slug limit by shortening the name - the fact's identity is its `component_id`, which is never touched); and its provenance is `catalog_reference` when a product snapshot was read from a catalog, `recipe_calculated` when the snapshot was calculated from a recipe's ingredients, and `user_confirmed` when the user recorded the value with no product behind it. |
| `facts[].label_name` | `IntakeComponent.name` | A compound or a blend carries the name as printed; a nutrient's code already names it, so it carries none. |
| `facts[].amount`, `.unit`, `.value_state` | the component's amount and unit, limited by the product snapshot's state | `known` carries both, spelled as the journal spells them; `unknown` and `not_applicable` carry neither, and `below_reporting_threshold` carries no amount. **Unknown is never zero.** A nutrient the snapshot states as unknown is encoded as `value_state: "unknown"` with no amount at all, and a nutrient the snapshot does not mention keeps the recorded amount. |
| `facts[].members` | `IntakeContextFactCatalog` | Blend members in label order; a member the label does not quantify carries its name only, because member amounts are never invented or split from the total. |
| `healthkit_links` | `[IntakeContextLink]?` | Carried when the HealthKit write plan gave one, empty otherwise: the field is required either way. A link has to name a nutrient of this revision - including a fact that came from the product snapshot, because `link_projection` takes that revision's snapshot and rebuilds its facts the same way the upsert did, so a barcode or recipe revision's nutrients can be linked even though no component names them - and its `healthkit_type` has to be the type that code lands in, so a link to a compound, a blend or an absent component is refused - and a `link_projection` is checked against the revision it names, exactly as an upsert's links are. The snapshot's own rules are checked too, because each is a permanent failure at the receiver: `sync_version` is at least 1, a `(component_id, sample)` pair appears once, one sample is active on at most one component, and within one `(component_id, healthkit_type, sync_identifier)` the versions are unique, only one sample is active, and an inactive link is never newer than the active one. The sync identifier is `HealthKitWritePlanner.syncIdentifier(intakeID:nutrientKey:)` and the sample UUID is lowercase canonical text. |
| `nutrition_completeness` | the product snapshot and the facts | `complete` only when a snapshot states a **known** value for every nutrient the app writes and no recorded fact is unknown; a snapshot that keeps an unknown entry states the gap and is never complete however many other nutrients it fills in. Otherwise it is `partial` when some source data is known and `unknown` when nothing is. It describes this intake's source data, not the day. |
| the three digests | `IntakeContextDigests` | Computed in the contract's order over the canonical bytes of the operation as sent, with the batch scope in place. |

## The three scopes
| Digest | Covers | Excludes |
|---|---|---|
| `domain_facts_hash` | `producer_id` from the batch plus the facts of the revision: `operation`, `intake_id`, `revision`, and the food details of an upsert or `deleted_at` of a delete. | `operation_id`, `projection_sequence`, `healthkit_links`, the three digests, `installation_id`. |
| `projection_hash` | `producer_id`, `intake_id`, `revision`, `projection_sequence` and the complete link snapshot, sorted by `(component_id, healthkit_sample_uuid)` by code point. | The order the app listed the links in; `installation_id`. |
| `client_payload_hash` | `producer_id`, `writer_bundle_id`, `installation_id` and `schema_version` from the batch plus the operation as sent, without its own `client_payload_hash`. | Nothing: it is the digest of the delivered content, and it covers the other two. |

A changed `display_name` moves the domain and client digests and leaves the projection digest alone. A changed
`installation_id` moves only the client digest. Reordering `healthkit_links` moves only the client digest,
because the projection digest sorts them.

## What the encoder refuses
Every refusal is something the receiver rejects as a permanent failure, caught before a digest is taken, so a
refusal here never costs a delivery attempt. `IntakeContextEncoderError` names the reason:

- an outbox row that is not this operation's: another intake, another revision, an action the method does not
  deliver, or a destination other than the relay;
- a producer scope that would fail the envelope: a `producer_id` that is not a slug, a `writer_bundle_id` outside
  the contract's pattern, an `installation_id` that is not a UUID;
- a link projection's delivery identity that is not lowercase canonical UUID text, and a tombstone that belongs
  to another intake;
- a product that is not the snapshot the revision names, or one supplied for a revision that names none;
- an empty component list, a repeated component id, a component id that is not a slug, or a negative amount;
- a time zone name that is unknown, or that the contract rejects as host-local: `Factory`, `localtime`,
  `posixrules`, `posix/`, `right/`;
- a blend with no members, because member amounts are never invented;
- a link to a component that is not a nutrient of the revision, a link whose type is not the one its code lands
  in, a repeated `(component, sample)` pair, a non-canonical sample UUID, a `sync_version` below 1, one sample
  active on two components, and the sync identity's unique versions, single active sample and ordering;
- a `link_projection` at sequence 1, an empty batch, a batch carrying another batch or another scope, and a
  `batch_id` or `installation_id` that is not UUID text.

## Tests
`ios/NutritionCore/Tests/NutritionJournalTests/IntakeContextDigestTests.swift` checks the worked digests and
the worked canonical projection bytes from the contract as literal vectors, recomputes every digest of every
operation in every committed fixture (loaded from `contracts/intake-context/fixtures` through `#filePath`, so
a stale copy cannot pass), and covers key order by code point, raw UTF-8 for non-ASCII text, the control
escapes, decimal spelling as content and link order under the projection digest.

`ios/NutritionCore/Tests/NutritionJournalTests/IntakeContextEncoderTests.swift` rebuilds
`valid_worked_example.json`, `valid_delete.json` and `valid_link_projection_seq2.json` from synthetic
`Intake`, `IntakeRevision`, `ProductDefinition` and `OutboxOperation` values and compares the canonical bytes
the encoder produced with the canonical bytes of each fixture, so the mapping table above is checked against
the receiver's own contract rather than against itself. It also covers decimal spelling, an unknown nutrient
that is never written as zero, compound and blend facts, ordinary food and recipe components with their
snapshot nutrients, the derived code limit, `recipe_calculated` provenance, the tombstone revision and its
persisted deletion instant, per-sequence projection identities, completeness, the link snapshot and its sync
identity rules, the injected producer scope, envelope field validation and UUID normalization, determinism,
and every refusal listed above.

Swift tests run in macOS CI; the acceptance for this package is static.
