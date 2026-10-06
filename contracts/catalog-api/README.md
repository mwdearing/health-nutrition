# catalog-api

The HTTP contract (request and response shapes) of the catalog service.

What is here for v1:

- `product-version.v1.schema.json` - one published version of one product, as
  JSON Schema 2020-12. Deny by default: every object level is closed, so a field
  that is not listed is refused. Amounts are exact decimal strings. The four
  nutrient value states (`known`, `unknown`, `not_applicable`,
  `below_reporting_threshold`) mirror the iOS `NutrientValue` cases; only
  `known` carries an amount.
- `error.v1.schema.json` - the closed two-field error body (`code`, `message`)
  used by every non-2xx response.
- `openapi.v1.yaml` - the OpenAPI 3.1 skeleton: `GET /v1/products/{product_id}`,
  `GET /v1/barcodes/{barcode}` and `GET /v1/search`. Bearer auth is required on
  every operation, so there are no anonymous reads, and no request or response
  carries a user identifier. v1 is read-only: writes come from the import
  service alone, which does not speak this API.

`product-version.v1.schema.json` is a root schema with no `$ref`, so validating a
product needs only that one file. `openapi.v1.yaml` references it as a sibling
file for tooling that resolves external references.

Nothing here names a real host, account or person.
