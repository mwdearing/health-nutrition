# Synthetic contract vectors

Validate operation fixtures against the root schema, response fixtures against the corresponding `$defs`. `*-invalid.json` must be rejected by schema or semantic validation; `oversize-16385-invalid.json` is structurally valid and fails the canonical byte bound. `renderer-input.json` is a renderer-only vector, not an operation; `renderer-expected.json` contains exact expected UTF-8 bytes without a trailing newline, and its metadata records byte length/SHA-256. Pretty whitespace in the input files does not count toward the operation limit.

| Fixture | Definition / additional expected result |
| --- | --- |
| name-only-valid, fact-states-valid | publish_request |
| exact-16384-valid | publish_request; canonical bytes 16384 |
| oversize-16385-invalid | publish_request; canonical bytes 16385; reject |
| unicode-120-valid | publish_request; 120 scalars accepted |
| unicode-121-invalid | reject name scalar bound |
| nested-private-invalid, serving-private-invalid | reject extra fields |
| withdraw-valid | withdraw_request |
| public-product-valid | public_product |
| search-response-valid | search_response |
| detail-response-valid | detail_response |
| own-state-none-valid | own_state |
| receipt-valid | receipt |
| capabilities-valid | capabilities |
| consent-receipt-valid | consent_receipt |
| error-valid | error_detail |

Consumers must also enforce numeric maximum, positive serving, unique keys, standard dimensions, per-serving numeric requirements, and verification status/source invariants documented in the contract. JSON Schema string maxLength counts scalars. These vectors use synthetic values only.

Additional semantic vectors: `amount-max-valid` accepts the numeric maximum; `amount-over-max-invalid` exceeds it; `dimension-invalid` supplies a volume for standard mass protein; `unknown-standard-invalid` uses a nonstandard case-sensitive key outside `ingredient:`; `threshold-amount-invalid` invents a threshold amount. Barcode vectors enforce GS1 checksum in addition to schema structure. Search vectors enforce the configured page bound. `unicode-normalization-vectors` is a normalization-only corpus.

`key-identity-valid` keeps composed/decomposed accented keys distinct and accepts a newline in a nonempty ingredient suffix. Consumers must compare exact UTF-8 keys for uniqueness.
`key-duplicate-invalid` repeats a byte-identical key and must fail semantic uniqueness validation.

`renderer-sql-input.json`/`renderer-sql-expected.json` cover the JSONB-representable scalar domain. The abstract renderer fixture retains U+0000 for client algorithm conformance; PostgreSQL rejects it before an RPC. `nul-text-invalid.json` requires client/schema rejection and a SQL JSONB-decoder rejection check. SQL tests also execute the unchanged exact 16384/16385-byte fixtures.
