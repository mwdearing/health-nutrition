# Open Food Facts: data source determination

Status: Accepted for live barcode lookup only. Terms review date: 2027-04-02.

## What is used

The app reads one product at a time from the Open Food Facts API v3
(`/api/v3/product/<barcode>`) after the user scans or types a barcode. The request
asks only for the fields it needs: code, product name, brands, serving size,
serving quantity, the basis of the nutrition data, the nutriments and the last
modification time. The use is read-only; the app never writes to Open Food Facts.

Nutrient amounts are decoded as decimal numbers. Open Food Facts normalises the
`_100g` and `_serving` values to canonical units (kcal for energy, grams for every
other nutrient), so the app reads them in those units and ignores the `_unit` field,
which only describes the unit the contributor typed. A nutriment the source does not
give, or gives as malformed text, is shown as unknown and never as zero.

Amounts in the `*_100g` and `*_serving` fields are read in the canonical units of
Open Food Facts (kcal for energy, grams for all other nutrients), and the `*_unit`
field is ignored because it only describes the unit the contributor entered.

The basis of the values is one of four cases:

- `perServing`: `nutrition_data_per` is "serving"; the `_serving` values are read.
- `per100ml`: otherwise, and the serving size text has a volume unit (ml, cl, dl, l,
  fl oz).
- `per100g`: otherwise, and the serving size text has a mass unit (g, mg, kg, oz).
- `per100Unspecified`: 100 g or 100 ml, the source does not say (no serving size, or
  a unit that is not recognised). Nothing is guessed.

The product always carries all nine standard nutrient keys; a missing one is unknown.

## Licences

- The database is available under the Open Database License (ODbL).
- The individual contents of the database are available under the
  Database Contents License (DbCL).
- Product images are licensed under CC BY-SA and are NOT used: the client has no
  image fields and no image handling.

## Obligations and how they are met

- Attribution: wherever a value from Open Food Facts is shown, the app shows the
  attribution text "Nutrition facts from Open Food Facts, available under the Open
  Database License (ODbL)." with a link to https://world.openfoodfacts.org. The
  text and link are constants in the provider package.
- Share-alike: the app does not build or publish a derived database. An entry the
  user confirms is stored only in the user's own journal on their own device and
  sync account.
- No bulk download, no mirror and no export of Open Food Facts data as a database.
- No images.
- No search and no search-as-you-type: lookups are by barcode only, started by an
  explicit user action.

## Etiquette and limits

- Every request sends a User-Agent of the form
  `HealthNutrition/<version> (https://github.com/mwdearing/health-nutrition/issues)`.
- Open Food Facts allows 100 product reads per minute per client. The client
  limits itself to 15 lookups in any rolling 60 seconds and answers further calls
  with a rate-limited outcome without sending a request. The window uses a monotonic
  clock. HTTP 429 and 503 are also reported as rate limited, using the Retry-After
  header (seconds or HTTP-date) when present.
- A barcode is checked locally first (digits only, EAN-8, UPC-A or EAN-13, correct
  check digit); an invalid barcode never causes a request.
- Tests use a stub transport and fixtures with invented values. The staging server
  (`world.openfoodfacts.net`) is for manual checks, never production data. Its
  basic-auth credentials are published in the Open Food Facts documentation; the
  caller injects the header value at manual-test time and it is never committed.

## Review

Re-read the Open Food Facts terms of use and the API documentation by 2027-04-02,
or sooner if they change, and update this note.
