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
| `batch_id` | the caller's delivery id, `batch(batchID:operations:)` | Transport only; no digest covers it, so a retry may reuse it. |
| `producer_id`, `writer_bundle_id`, `installation_id` | the injected `IntakeContextProducerScope` | Inside `client_payload_hash`; `producer_id` is also inside the other two, so the same intake id from another producer never collides. |
| `operations` | `upsert(...)`, `delete(...)`, `linkProjection(...)` | Array order is the receiver's apply order, so the caller's order is kept. |
| `operation_id` | `OutboxOperation.operationID` | The delivery identity: the same id with the same `client_payload_hash` is a duplicate, and with a different one a conflict. |
| `operation` | `OutboxOperation.kind`, or `linkProjection(...)` | `upsert`, `delete` or `link_projection`. |
| `intake_id` | `Intake.id` | Lowercase UUID. An operation whose outbox row names another intake or another revision is refused. |
| `revision` | `IntakeRevision.number` | Monotonic per intake; a delete must carry a higher revision than any accepted one. |
| `projection_sequence` | 1 for an upsert, the caller's sequence for a link projection | An upsert opens the projection lifecycle of its revision, so it is always 1; a link-only change starts at 2 and carries the complete snapshot. |
| `occurred_at` | `Intake.occurredAt` | Written in `Intake.timeZoneIdentifier` with that zone's offset at the instant, so the wall clock and the instant agree. An unknown zone name is refused rather than silently replaced by the device's zone. |
| `time_zone` | `Intake.timeZoneIdentifier` | An IANA name, never a host-local key. |
| `recorded_at`, `deleted_at` | `IntakeRevision.createdAt`, the caller's deletion instant | Instants rather than wall clocks, so they are written in UTC. |
| `category` | `Intake.category` | The journal's slug. |
| `display_name` | `ProductDefinition.name`, else `Intake.meal`, else `Intake.note`, else `Intake.category` | The first non-empty of those. |
| `serving` | the revision's components | The first component measured by volume, else the first measured by count, else the first component. The journal has no serving of its own. |
| `facts` | the revision's components | One fact per component, in component order, which is part of the hashed content. |
| `facts[].component_id` | `IntakeComponent.componentID` | A slug, unique within the operation; a repeated one is refused. |
| `facts[].kind`, `.code`, `.aggregation_role`, `.quantity_basis`, `.provenance` | `IntakeContextFactCatalog` | The kind fixes the role: a nutrient is `context_only`, a compound is `compound_measurement` and needs a basis, a blend is `blend_total_only` and needs members. A component with no catalog row is refused, because no code is invented for it. |
| `facts[].label_name` | `IntakeComponent.name` | A compound or a blend carries the name as printed; a nutrient's code already names it, so it carries none. |
| `facts[].amount`, `.unit`, `.value_state` | the component's amount and unit, limited by the product snapshot's state | `known` carries both, spelled as the journal spells them; `unknown` and `not_applicable` carry neither, and `below_reporting_threshold` carries no amount. **Unknown is never zero.** A nutrient the snapshot states as unknown is encoded as `value_state: "unknown"` with no amount at all, and a nutrient the snapshot does not mention keeps the recorded amount. |
| `facts[].members` | `IntakeContextFactCatalog` | Blend members in label order; a member the label does not quantify carries its name only, because member amounts are never invented or split from the total. |
| `healthkit_links` | `[IntakeContextLink]?` | Carried when the HealthKit write plan gave one, empty otherwise: the field is required either way. A link has to name a nutrient fact of the same upsert and its `healthkit_type` has to be the type that fact's code lands in, so a link to a compound or a blend is refused. The sync identifier is `HealthKitWritePlanner.syncIdentifier(intakeID:nutrientKey:)` and the sample UUID is lowercase canonical text. |
| `nutrition_completeness` | the product snapshot and the facts | `complete` when a snapshot states a known value for every nutrient the app writes, `partial` when some source data is known, `unknown` when nothing is. It describes this intake's source data, not the day. |
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
that is never written as zero, compound and blend facts, the link snapshot, the injected producer scope,
determinism, and the refusals the receiver would make anyway.

Swift tests run in macOS CI; the acceptance for this package is static.
