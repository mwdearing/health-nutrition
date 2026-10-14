# catalog-api

The HTTP contract (request and response shapes) of the catalog service.

What is here for v1:

- `product-version.v1.schema.json` - one published version of one product, as
  JSON Schema 2020-12. Deny by default: every object level is closed, so a field
  that is not listed is refused. The `nutrients` object accepts only the
  nutrient ids of `contracts/nutrients/registry.v1.json`, each with the units the
  registry lists for it. Amounts are exact decimal strings of at most 12 integer and 6 fraction
  digits, and never negative;
  the serving is a positive amount in a mass, volume or count unit. Names, brands
  and attribution lines may be in any script, without control characters,
  direction marks or overrides, zero-width or other invisible format characters,
  or a space at either end. The four nutrient value states (`known`, `unknown`,
  `not_applicable`, `below_reporting_threshold`) mirror the iOS `NutrientValue`
  cases; only `known` carries an amount.
- `error.v1.schema.json` - the closed two-field error body (`code`, `message`)
  used by every non-2xx response.
- `openapi.v1.yaml` - the OpenAPI 3.1 skeleton: `GET /v1/products/{product_id}`,
  `GET /v1/barcodes/{barcode}` and `GET /v1/search`. The version prefix is part
  of each path, so the server URL carries none. Bearer auth is required on
  every operation, so there are no anonymous reads, and no request or response
  carries a user identifier. v1 is read-only: writes come from the import
  service alone, which does not speak this API.

`product-version.v1.schema.json` is a root schema with no external `$ref`, so
validating a product needs only that one file. `openapi.v1.yaml` references it as a sibling
file for tooling that resolves external references.

Nothing here names a real host, account or person.
