# Shared catalog products v2

This additive contract leaves legacy catalog responses and verification thresholds unchanged. The JSON Schema `$defs` are the strict request and response interfaces. All objects reject additional properties, at every nesting level. Nullable product fields are required unless explicitly optional in the schema. No identity, ownership, consumed quantity, intake time, meal, journal identifier, note, goal, photo or device field is accepted.

## RPC interface

Every RPC returns one JSON object, never a table or array wrapper. PostgREST wraps operation bodies in `p_request`; this wrapper does not participate in canonical body identity or the byte limit.

| RPC | Arguments | Response `$defs` |
| --- | --- | --- |
| `catalog_capabilities_v2()` | none | `capabilities` |
| `acknowledge_catalog_consent_v2(p_version integer)` | `consent_request` | `consent_receipt` |
| `submit_catalog_product_v2(p_request jsonb)` | `publish_request` | `receipt` |
| `resolve_catalog_publish_for_withdrawal_v2(p_request jsonb)` | exact original `publish_request` | `publish_resolution` |
| `withdraw_catalog_product_v2(p_request jsonb)` | `withdraw_request` | `receipt` |
| `search_catalog_products_v2(p_query text,p_kind text default null,p_cursor text default null,p_limit integer default 20)` | `search_request` | `search_response` |
| `get_catalog_product_v2(p_product_id uuid)` | `detail_request` | `detail_response` |
| `get_my_catalog_contribution_v2(p_product_id uuid)` | `detail_request` | `own_state` |

A missing public product returns `{"product":null}`. Never-contributed own state returns the requested product ID, `current_revision:null` and `current_state:"none"`. Cursors are opaque server strings; callers must not derive ordering from them. The server currently encodes version, query/kind fingerprint, UUID and base64 original-name UTF-8 source, then reconstructs the normalized keyset boundary from that immutable source. It bounds decoded source to 120 scalars/480 bytes and the full token to 1024 bytes; this avoids unbounded cursor growth when NFKC expands a valid name. This format is private to the server and clients must not parse it. Search accepts 1–20 results, default 20. Query is trimmed and must contain 2–120 Unicode scalars. Cursor is at most 1024 UTF-8 bytes and bound to the query/kind fingerprint. Percent, underscore and backslash match literally through parameterized search. Every page rechecks live moderation visibility. Kind null means all kinds.

`acknowledged_revision` is the immutable contribution revision acknowledged by that operation; `current_revision` and `current_state` describe the caller's present contribution. A replay returns the original acknowledgment with `replayed:true` and current state/publication. Reusing an operation ID with a different canonical request is `operation_conflict`. UUID strings accept canonical hyphenated uppercase or lowercase hexadecimal spelling; braces and dashless aliases are invalid. Parsed UUID identity is case insensitive, while canonical request bytes preserve string spelling. Updates require the caller's current expected revision; new publication uses null product ID and null expected revision. Withdrawal requires both IDs and expected revision, and stays available while sharing is disabled. Reenable does not restore withdrawn operations. Revisions and generations are unsigned decimal strings, with revisions starting at 1. Support counts are decimal strings too.

Publication is the public product or null if no active representative exists. Public products carry their content under `product`, with immutable `representative_revision`, public attribution under `source`, support counts and separate alternatives. No contributor UUID is exposed. Alternatives retain distinct support counts; never average conflicting facts or merge products by name. Support thresholds are configuration, not an automatic verification rule.

## Verification and permission

The first active contribution is searchable with status `shared_unverified`, shown as “Shared, not yet verified.” Verification requires `verification.status:"verified"` and `verification.source:"owner_reviewed"`; all unreviewed publications have status `shared_unverified` and source null, regardless of agreement count. Name-only content cannot verify. The catalog security design still requires owner review; this contract does not implement moderation. `missing_facts` is true when no facts have a known numeric amount; unknown, not applicable and below threshold never invent an amount.

Sharing requires a live nonanonymous account, loaded profile, sharing permission, and acknowledgment of consent version 2 at the current server generation. Capabilities expose caller acknowledgment only as version/generation; no account identity. Capabilities are advisory, and writes recheck authorization. Consent generation preserves server decimal spelling. Disabled capabilities produce `unavailable` for writes, except permitted withdrawal and publication resolution. Consent acknowledgment does not publish content.

## Semantic validation

Lengths count Unicode scalars, and bounds apply both before and after NFC display normalization (fact keys remain unnormalized): name 1–120 nonblank, brand at most 80, serving text at most 80, fact key 1–64 nonblank, display name 1–120 nonblank. Optional brand and barcode may be null. Supplied barcode is ASCII digits only, length 8 (EAN-8), 12 (UPC-A) or 13 (EAN-13), with correct GS1 check digit. Empty supplied barcode is rejected; callers may turn empty input into null before validation. Barcode equivalence only joins UPC-A to its leading-zero EAN-13 form. Facts contain at most 64 unique case-sensitive keys. Standard keys are exactly the schema enumeration. Additional compounds require a nonempty `ingredient:` suffix. Unknown standard keys are rejected; namespace does not imply a chemical equivalence.

Ordinary nonnegative decimal strings match the schema grammar, have at most six fractional digits, are finite and at most 1000000000. Signs, exponent notation, whitespace, leading zeros (except zero itself), NaN and Infinity are rejected. Serving quantity must be strictly positive and use mass, volume or count. Numeric per-serving facts require a serving definition. Threshold facts have no amount and may have a unit; unknown and not_applicable have neither. Known zero remains known.

`energyKcal` has energy dimension. All other standard keys have mass dimension. This includes vitaminD; IU is permitted for ingredient facts and retained without conversion, but never inferred equivalent to mass. Threshold unit dimensions obey the same rules as known facts. Units are the closed canonical registry in the schema, including case-sensitive `mL`, `L`, `IU` and `fl oz`; kJ is unsupported.

## Display, search and equivalence

Keep original display facts, units and decimal spelling. Display normalization is Unicode NFC, without case folding or whitespace collapse. Search normalization is Unicode NFKC followed by locale-independent Unicode lowercase (not casefold), then collapse each maximal run of Unicode White_Space characters to one ASCII space and trim those spaces. Use platform NFC for display. The server is authoritative for search normalization; clients send trimmed query and never use search normalization as identity. The Unicode conformance fixture corpus freezes representative behavior without assuming identical Unicode versions on all platforms. Key identity stays case sensitive and unnormalized: composed and decomposed scalar sequences are distinct. Compare exact UTF-8 bytes (or Unicode scalar sequences); do not use Swift String canonical-equivalence equality, locale collation or other normalized String-keyed containers as wire key identity. ProductFact equality/hashing preserves exact key bytes; display names retain ordinary platform String equality, and full product equality is not shared fact-equivalence normalization. Ingredient suffixes may contain line terminators; canonical rendering escapes control characters and the same scalar bounds apply.

Fact equivalence compares case-sensitive keys and states, excluding display names. Unknown and not_applicable compare only within the same state. Threshold facts require the same optional unit; no threshold amount is synthesized. Known facts normalize insignificant decimal zeros and compare within a dimension after exact conversion to the base unit. Mass factors in grams: g=1, mg=.001, mcg=.000001, kg=1000, oz=28.349523125. Volume factors in mL: mL=1, L=1000, fl oz=29.5735295625, cup=236.5882365, tbsp=14.78676478125, tsp=4.92892159375. Energy is kcal only. IU converts only to IU. Count units compare only with the identical count symbol; no unlike-count or count/mass/volume conversion is inferred. Exact equivalence uses rational decimal multiplication, never binary floats or rounded reciprocal conversion. The existing Domain display conversion into reciprocal units rounds to 10 digits; that display operation must not decide shared equivalence. Fact order does not affect equivalence; canonical receipt identity preserves array order. Product kind and basis, and serving quantity/dimension after the same exact compatible-unit conversion, must agree for product equivalence. Optional serving text is display metadata, excluded from agreement but preserved on the actual representative and in canonical receipt identity; no automatic per-serving to per-100 conversion.

## Canonical operation bytes

Reject an operation when its entire canonical UTF-8 envelope exceeds 16384 bytes. This bounds accepted canonical content, not HTTP whitespace; existing gateway limits remain separate. Neither JSONB storage size nor platform-default JSON serialization defines this bound.

Render recursively: object keys sorted lexicographically by Unicode scalar values (not UTF-16 code units); compact `,` and `:` separators; arrays retain order; booleans/null use lowercase JSON tokens. Emit Unicode scalars directly in UTF-8, except quote and backslash use `\"` and `\\`, and U+0000–U+001F use lowercase four-digit `\u00xx` escapes. Never short escapes, whitespace, slash escaping or Unicode normalization. Canonicalize the PostgREST-decoded JSONB object semantics; duplicate raw keys may already have been resolved by that parser. Client encoders emit unique keys. Invalid Unicode/surrogates are not valid scalar inputs. U+0000 is excluded from all operation/product/search text because PostgreSQL JSONB cannot represent it. Clients must reject U+0000 before transport. The abstract canonical renderer corpus includes U+0000 only to test the rendering algorithm; the SQL transport corpus excludes it and separately asserts the JSONB decoder rejection. A decoder rejection happens before the RPC and cannot carry our P0001 JSON detail; providers map invalid-input transport responses safely and must not treat them as acknowledgments. The only operation numeric token is consent_version, rendered as integer `2`. Amounts, counts, revisions and generations remain strings; preserve decimal spelling for idempotency identity. Hash canonical bytes if a digest is needed. The renderer fixture includes a BMP/astral key-order boundary, combining marks, control characters, quotes and slash. Boundary fixtures have canonical lengths exactly 16384 and 16385.

## Errors

Application errors use SQLSTATE `P0001` and JSON DETAIL matching `error_detail`. Codes are `invalid_request`, `unauthorized`, `consent_required`, `revision_conflict`, `operation_conflict`, `rejected`, `rate_limited`, `unavailable`. Optional metadata is restricted to field path, current revision/state, consent generation and retry-after seconds; never include request bodies, identities or private server details. Invalid payloads use `invalid_request`; revision conflicts provide current revision/state; consent errors may provide generation; throttling may provide retry-after. Reject reasons use `rejected` without freeform private messages. Clients additionally handle HTTP 401/403 as authorization failures, 409 as conflicts, 429 as rate limiting, 5xx as unavailable, malformed responses as unavailable, and cancellation as cancellation without retry publication. Error responses do not count as delivery acknowledgments.

### Legacy read content

Publication content (`public_product.product` and each `alternative.product`) is a
`read_product` union. Custom content keeps the strict existing `product` shape.
Legacy content has the exclusive `content_type: "legacy_label"` discriminator and
exact fields `name`, `brand`, `barcode`, `kind: null`, `basis`, `serving: null`,
`raw_serving_text`, `nutrients`, and `legacy_source`. Legacy basis retains
`per_100g`, `per_100ml`, or `per_serving`; nutrients retain the original bounded
numeric object, including `salt` in grams and `sodium` in milligrams. Original
nullable serving text is preserved up to 80 Unicode scalars. No kind or structured
serving is inferred. These read shapes are also used by search, detail, and receipt
publication, including replay. The publication request schema remains unchanged.

`legacy_source` is `community` or `owner_reviewed`. A legacy alternative carries
its own required `source` and `verification` alongside revision, product and
support. Custom alternatives retain their existing shape. Only the exact
owner-reviewed legacy payload can have its legacy verified badge; automatic
legacy agreement is unverified on the v2 surface. Legacy and custom support counts
are independent even for matching facts. Root `product_id` is shared by all bases
of a canonical barcode; UPC-A and its leading-zero EAN-13 share that identity.
Legacy source revisions are allocated immutable snapshot identifiers, never
wall-clock timestamps, and do not identify an account or a submission.

Importing unresolved legacy content creates a staged editor draft. The user must
choose a kind and, when needed, a numeric serving before constructing a valid
custom revision or publishing. Import and logging alone never add support. The
completed revision retains source attribution and original serving text.

Both API generations use the existing daily submission ledger. Every account
operation locks its live profile before the complete sorted signed-bigint advisory
key set (v2 barcode and all three legacy barcode/basis keys), followed by products
in UUID order, contributions, usage and derived rows. Account erasure precollects
all affected identities and removes both generations through `delete_my_account`.
Root rejection suppresses both lookup generations; legacy basis rejection also
suppresses corresponding custom alternatives. Receipt replay reflects current
visibility without consuming quota or changing the accepted revision.

## Resolving a publication before withdrawal

`resolve_catalog_publish_for_withdrawal_v2` is the eighth RPC. Call it only for an
explicit, durable cancellation or withdrawal dependency, with the **exact original
publish envelope**, including operation/client-revision UUID spelling, product,
expected revision, consent fields, decimal strings and array order. Owner identity
stays outside the wire request and is checked against the session before bearer use
and after refresh. The request has the same strict shape and 16384 canonical UTF-8
byte bound as publication. No replacement operation UUID is created for resolution.

The closed `publish_resolution` union is one of:

- `{"outcome":"committed","receipt":<receipt>}`: the existing ordinary receipt,
  with `replayed:true`. `acknowledged_revision` belongs to the original publication;
  current revision, state and publication reflect the current contribution.
- `{"outcome":"canceled_before_commit","operation_id":"<UUID>","replayed":false}`:
  an atomic, durable fence against this publication committing. A matching replay
  returns the same shape with `replayed:true`. This outcome has no product identity,
  receipt, revision, publication or contribution state.

Resolution never invokes publication or allocates a catalog identity. Under the
live profile lock it checks the existing receipt first, then the private cancellation
marker, comparing exact canonical UTF-8 bytes. Receipt or marker replays precede
fresh semantic validation and resource limits. A fresh marker validates the full
publish envelope and product, without enforcing sharing permission, current consent,
feature enablement, product existence, barcode binding, moderation or revision CAS.
It is allowed with sharing off, no acknowledgment, stale consent or `enabled:false`.

Markers reserve `(account, operation UUID)` until account deletion and retain the
bounded exact canonical body privately. Both ordinary publish and withdrawal return
permanent `operation_conflict` for a canceled UUID, regardless of supplied body.
A different body under the same UUID also conflicts on resolution. Existing receipts
retain their original replay semantics. Matching UUIDs are parsed case insensitively;
changing their spelling in the canonical body still changes operation identity.
Neither fresh consent, off/on transitions, withdrawal-all, nor a timer clears markers.
Profile erasure cascades them; stale sessions cannot resurrect deleted accounts.
Direct table/helper access is denied to application roles. Rollback must preserve
the fence or disable affected writes; dropping markers and restoring an unfenced
writer violates completed cancellations.

New servers advertise `publish_resolution_version:1` in capabilities. This field is
optional for older v2 backends. Clients enable resolution only for exactly version 1;
absent, zero or unknown future versions leave the intent pending as unsupported.
The capability is independent of publication `enabled`. A missing endpoint after
advertisement is a deployment inconsistency: retain pending state and refresh
capabilities. Never fall back to submit, silently change sharing preferences, or
interpret malformed transport success as an acknowledgment.

A separate private setting allows 256 new markers per account per UTC day (integer
range 1–10000). Identical receipt/marker replays bypass the limit. Exhaustion returns
`rate_limited` with decimal-string `retry_after_seconds` from 1 to 86400, bounded by
the next UTC day, and creates no marker. Retain the intent and retry its identical
body with bounded backoff. Publication usage/quota is unchanged. Markers have no TTL
or lifetime pruning because delayed requests must remain fenced until account deletion.

Cancellation only resolves the attempted operation. A canceled first publication
with no known identity creates no fake product ID. A canceled update leaves any
previous contribution intact: fetch its known product's own state and withdraw with
a fresh operation and the deliberately reviewed expected revision. A committed
resolution likewise needs an ordinary CAS withdrawal if its contribution is still
active. A newer revision requires deliberate conflict review; never substitute it
automatically. Resolve every uncertain predecessor in a pending dependency chain.
A later independent publication under a new UUID may race and must not be removed
by a stale withdrawal or displayed as already removed.
