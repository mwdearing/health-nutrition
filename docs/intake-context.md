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

Swift tests run in macOS CI; the acceptance for this package is static.
