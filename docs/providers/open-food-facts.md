# Open Food Facts: data source determination

Status: Accepted for live barcode lookup only. Terms review date: 2027-04-02.

## What is used

The app reads one product at a time from the Open Food Facts API v3
(`/api/v3/product/<barcode>`) after the user scans or types a barcode. The request
asks only for the fields it needs: code, product name, brands, serving size,
serving quantity, the basis of the nutrition data, the nutriments and the last
modification time. The use is read-only; the app never writes to Open Food Facts.

Nutrient amounts are decoded as decimal numbers. A nutriment the source does not
give, or gives with a unit the app does not know, is shown as unknown and never
as zero.

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
  with a rate-limited outcome without sending a request. HTTP 429 and 503 are also
  reported as rate limited, using the Retry-After header when present.
- A barcode is checked locally first (digits only, EAN-8, UPC-A or EAN-13, correct
  check digit); an invalid barcode never causes a request.
- Tests use a stub transport and fixtures with invented values. The staging server
  (`world.openfoodfacts.net`, shared basic-auth credentials, sent only to staging)
  is for manual checks, never production data.

## Review

Re-read the Open Food Facts terms of use and the API documentation by 2027-04-02,
or sooner if they change, and update this note.
