# Contracts

Shared, language-neutral definitions that the iOS app and the catalog service
both build against. Examples in this tree are synthetic.

- `nutrients/` - the nutrient vocabulary: identifiers, units and conversions.
  Holds `registry.v1.json`, `decimal-rules.md` and `golden.v1.json`.
- `catalog-api/` - the HTTP contract of the catalog service. Holds the product
  version schema, the error schema and the OpenAPI skeleton.
- `intake-context/` - the operation batch a registered producer sends.
- `journal-export/` - the export envelope of the on-device journal.
- `providers/` - how external food-data providers map into the catalog.

Catalog contract v1 is the deny-by-default boundary: the public catalog exposes
catalog facts only, to signed-in callers only. Every schema is closed at every
object level, so a field that is not listed - in particular anything identifying
a person, a device or an intake - is refused rather than ignored. Amounts are
exact decimal strings, never JSON numbers.

`catalog/tests/test_contract_v1.py` validates the schemas, the registry and every
golden vector in CI.
