# Shared catalog products v2

This additive contract leaves legacy catalog responses and verification thresholds unchanged. The JSON Schema `$defs` are the strict request and response interfaces. All objects reject additional properties, at every nesting level. Nullable product fields are required unless explicitly optional in the schema. No identity, ownership, consumed quantity, intake time, meal, journal identifier, note, goal, photo or device field is accepted.

## RPC interface

Every RPC returns one JSON object, never a table or array wrapper. PostgREST wraps operation bodies in `p_request`; this wrapper does not participate in canonical body identity or the byte limit.

| RPC | Arguments | Response `$defs` |
| --- | --- | --- |
| `catalog_capabilities_v2()` | none | `capabilities` |
| `acknowledge_catalog_consent_v2(p_version integer)` | `consent_request` | `consent_receipt` |
| `submit_catalog_product_v2(p_request jsonb)` | `publish_request` | `receipt` |
| `withdraw_catalog_product_v2(p_request jsonb)` | `withdraw_request` | `receipt` |
| `search_catalog_products_v2(p_query text,p_kind text default null,p_cursor text default null,p_limit integer default 20)` | `search_request` | `search_response` |
| `get_catalog_product_v2(p_product_id uuid)` | `detail_request` | `detail_response` |
| `get_my_catalog_contribution_v2(p_product_id uuid)` | `detail_request` | `own_state` |

A missing public product returns `{"product":null}`. Never-contributed own state returns the requested product ID, `current_revision:null` and `current_state:"none"`. Cursors are opaque server strings; callers must not derive ordering from them. Search accepts 1–20 results, default 20. Query is trimmed and must contain 2–120 Unicode scalars. Cursor is at most 1024 UTF-8 bytes and bound to the query/kind fingerprint. Percent, underscore and backslash match literally through parameterized search. Every page rechecks live moderation visibility. Kind null means all kinds.

`acknowledged_revision` is the immutable contribution revision acknowledged by that operation; `current_revision` and `current_state` describe the caller's present contribution. A replay returns the original acknowledgment with `replayed:true` and current state/publication. Reusing an operation ID with a different canonical request is `operation_conflict`. Updates require the caller's current expected revision; new publication uses null product ID and null expected revision. Withdrawal requires both IDs and expected revision, and stays available while sharing is disabled. Reenable does not restore withdrawn operations. Revisions and generations are unsigned decimal strings, with revisions starting at 1. Support counts are decimal strings too.

Publication is the public product or null if no active representative exists. Public products carry their content under `product`, with immutable `representative_revision`, public attribution under `source`, support counts and separate alternatives. No contributor UUID is exposed. Alternatives retain distinct support counts; never average conflicting facts or merge products by name. Support thresholds are configuration, not an automatic verification rule.

## Verification and permission

The first active contribution is searchable with status `shared_unverified`, shown as “Shared, not yet verified.” Verification requires `verification.status:"verified"` and `verification.source:"owner_reviewed"`; all unreviewed publications have status `shared_unverified` and source null, regardless of agreement count. Name-only content cannot verify. The catalog security design still requires owner review; this contract does not implement moderation. `missing_facts` is true when no facts have a known numeric amount; unknown, not applicable and below threshold never invent an amount.

Sharing requires a live nonanonymous account, loaded profile, sharing permission, and acknowledgment of consent version 2 at the current server generation. Capabilities expose caller acknowledgment only as version/generation; no account identity. Capabilities are advisory, and writes recheck authorization. Consent generation preserves server decimal spelling. Disabled capabilities produce `unavailable` for writes, except permitted withdrawal. Consent acknowledgment does not publish content.

## Semantic validation

Lengths count Unicode scalars, before display normalization: name 1–120 nonblank, brand at most 80, serving text at most 80, fact key 1–64 nonblank, display name 1–120 nonblank. Optional brand and barcode may be null. Supplied barcode is ASCII digits only, length 8 (EAN-8), 12 (UPC-A) or 13 (EAN-13), with correct GS1 check digit. Empty supplied barcode is rejected; callers may turn empty input into null before validation. Barcode equivalence only joins UPC-A to its leading-zero EAN-13 form. Facts contain at most 64 unique case-sensitive keys. Standard keys are exactly the schema enumeration. Additional compounds require a nonempty `ingredient:` suffix. Unknown standard keys are rejected; namespace does not imply a chemical equivalence.

Ordinary nonnegative decimal strings match the schema grammar, have at most six fractional digits, are finite and at most 1000000000. Signs, exponent notation, whitespace, leading zeros (except zero itself), NaN and Infinity are rejected. Serving quantity must be strictly positive and use mass, volume or count. Numeric per-serving facts require a serving definition. Threshold facts have no amount and may have a unit; unknown and not_applicable have neither. Known zero remains known.

`energyKcal` has energy dimension. All other standard keys have mass dimension. This includes vitaminD; IU is permitted for ingredient facts and retained without conversion, but never inferred equivalent to mass. Threshold unit dimensions obey the same rules as known facts. Units are the closed canonical registry in the schema, including case-sensitive `mL`, `L`, `IU` and `fl oz`; kJ is unsupported.

## Display, search and equivalence

Keep original display facts, units and decimal spelling. Display normalization is Unicode NFC, without case folding or whitespace collapse. Search normalization is Unicode NFKC followed by locale-independent Unicode lowercase (not casefold), then collapse each maximal run of Unicode White_Space characters to one ASCII space and trim those spaces. Use platform NFC for display. The server is authoritative for search normalization; clients send trimmed query and never use search normalization as identity. The Unicode conformance fixture corpus freezes representative behavior without assuming identical Unicode versions on all platforms. Key identity stays case sensitive and unnormalized.

Fact equivalence compares case-sensitive keys and states, excluding display names. Unknown and not_applicable compare only within the same state. Threshold facts require the same optional unit; no threshold amount is synthesized. Known facts normalize insignificant decimal zeros and compare within a dimension after exact conversion to the base unit. Mass factors in grams: g=1, mg=.001, mcg=.000001, kg=1000, oz=28.349523125. Volume factors in mL: mL=1, L=1000, fl oz=29.5735295625, cup=236.5882365, tbsp=14.78676478125, tsp=4.92892159375. Energy is kcal only. IU converts only to IU. Count units compare only with the identical count symbol; no unlike-count or count/mass/volume conversion is inferred. Exact equivalence uses rational decimal multiplication, never binary floats or rounded reciprocal conversion. The existing Domain display conversion into reciprocal units rounds to 10 digits; that display operation must not decide shared equivalence. Fact order does not affect equivalence; canonical receipt identity preserves array order. Product basis and serving must agree for product equivalence; no automatic per-serving to per-100 conversion.

## Canonical operation bytes

Reject an operation when its entire canonical UTF-8 envelope exceeds 16384 bytes. This bounds accepted canonical content, not HTTP whitespace; existing gateway limits remain separate. Neither JSONB storage size nor platform-default JSON serialization defines this bound.

Render recursively: object keys sorted lexicographically by Unicode scalar values (not UTF-16 code units); compact `,` and `:` separators; arrays retain order; booleans/null use lowercase JSON tokens. Emit Unicode scalars directly in UTF-8, except quote and backslash use `\"` and `\\`, and U+0000–U+001F use lowercase four-digit `\u00xx` escapes. Never short escapes, whitespace, slash escaping or Unicode normalization. Canonicalize the PostgREST-decoded JSONB object semantics; duplicate raw keys may already have been resolved by that parser. Client encoders emit unique keys. Invalid Unicode/surrogates are not valid scalar inputs. The only operation numeric token is consent_version, rendered as integer `2`. Amounts, counts, revisions and generations remain strings; preserve decimal spelling for idempotency identity. Hash canonical bytes if a digest is needed. The renderer fixture includes a BMP/astral key-order boundary, combining marks, control characters, quotes and slash. Boundary fixtures have canonical lengths exactly 16384 and 16385.

## Errors

Application errors use SQLSTATE `P0001` and JSON DETAIL matching `error_detail`. Codes are `invalid_request`, `unauthorized`, `consent_required`, `revision_conflict`, `operation_conflict`, `rejected`, `rate_limited`, `unavailable`. Optional metadata is restricted to field path, current revision/state, consent generation and retry-after seconds; never include request bodies, identities or private server details. Invalid payloads use `invalid_request`; revision conflicts provide current revision/state; consent errors may provide generation; throttling may provide retry-after. Reject reasons use `rejected` without freeform private messages. Clients additionally handle HTTP 401/403 as authorization failures, 409 as conflicts, 429 as rate limiting, 5xx as unavailable, malformed responses as unavailable, and cancellation as cancellation without retry publication. Error responses do not count as delivery acknowledgments.
