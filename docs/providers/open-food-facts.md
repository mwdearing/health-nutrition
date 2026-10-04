# Open Food Facts: data source determination

Status: Accepted for live barcode lookup only. Terms review date: 2027-04-02.

## What is used

The app reads one product at a time from the Open Food Facts API v3
(`/api/v3/product/<barcode>`) after the user scans or types a barcode. The request
asks only for the fields it needs: code, product name, brands, serving size,
serving quantity, the basis of the nutrition data, the nutriments and the last
modification time and the unit of the product quantity. The use is read-only; the app never writes to Open Food Facts.

Nutrient amounts are decoded as decimal numbers. Open Food Facts normalises the
`_100g` and `_serving` values to canonical units (kcal for energy, grams for every
other nutrient), so the app reads them in those units and ignores the `_unit` field,
which only describes the unit the contributor typed. A nutriment the source does not
give, or gives as malformed text, is shown as unknown and never as zero.

Amounts in the `*_100g` and `*_serving` fields are read in the canonical units of
Open Food Facts (kcal for energy, grams for all other nutrients), and the `*_unit`
field is ignored because it only describes the unit the contributor entered.

The basis of the values is one of four cases. Only `nutrition_data_per` and
`product_quantity_unit` decide it; the serving size text is kept as text and is never
used to infer the basis.

- `perServing`: `nutrition_data_per` is "serving"; the `_serving` values are read.
- `per100ml`: otherwise, and `product_quantity_unit` is "ml" (any case).
- `per100g`: otherwise, and `product_quantity_unit` is "g" (any case).
- `per100Unspecified`: 100 g or 100 ml, the source does not say (the unit is missing
  or anything else). Nothing is guessed.

The product always carries all nine standard nutrient keys; a missing one is unknown.

## In the app

Add intake has a barcode field with a Look up button. The request is sent only when the user taps
that button or submits the field; there is no search and nothing is sent while the user types. A
lookup needs 8, 12 or 13 digits with a correct check digit, checked locally before the request, so a
barcode the API would reject anyway is answered with a message and no request at all.

The lookup runs through the `BarcodeProductLookup` protocol in the UI package, which knows only the
shape of a product (barcode, name, brand, basis, nine nutrient values, the attribution and the
serving definition). The app target injects the implementation that talks to the API and fills in the
attribution from `OpenFoodFactsAttribution`, so the UI shows the required wording and link without
ever naming the source. One client is built at startup, with the required User-Agent, and shared, so
its rolling rate-limit window is not reset by reopening the form.

Each outcome has its own message on the form:

- found: the name and brand are filled in and the nutrients the source gives are shown per the basis
  it states (per 100 g, per 100 mL or per serving, with the serving size spelled out for per-serving
  values; the source may give that size as text only, such as "1 biscuit"). A nutrient the source
  does not give stays unknown and is never shown or stored as zero. The attribution text and link sit
  under the values.
- not found: the form keeps whatever the user typed, so they can enter the details themselves.
- rate limited or failed: nothing is filled in and the user is told how long to wait when the source
  said so through Retry-After.
- invalid barcode: the message names the accepted lengths and the check digit, and no request is sent.

A reply is applied only if it is still the newest lookup and the field still holds the barcode that
was asked for, so a slow answer can never fill the form with another product's values. Codes are
compared with their leading zeros ignored, because a UPC-A is answered as a GTIN-13 with a leading
zero; an answer for a genuinely different code is ignored.

Not found, rate limited and failed all clear what the previous lookup put into the form, so a second
barcode that finds nothing cannot leave the first product's values or its snapshot attached to the
next entry. A field the user edited after the lookup is left as they typed it.

Saving writes a product snapshot with the entry, carrying the barcode, brand and basis as they stand
in the form, plus the attribution source and the source's last-modified time. The snapshot id covers
every stored field, so saving one product twice under two different names gives two snapshots. The
journal's product record holds no nutrient values, so the prefilled nutrients stay on the form;
storing them needs a change to the journal type.

The amount, unit and time are never taken from the source: the user confirms how much they ate.

Scanning a barcode with the camera is a way of typing it. The scanner recognizes only EAN and UPC
codes and hands its raw payload to `ScannedBarcode.normalize`, which applies the same rule the field
applies to typed digits: 8, 12 or 13 digits with a correct GS1 check digit, anything else ignored.
The first payload that passes fills the barcode field and closes the scanner; no request is sent
while the camera is open, and the lookup still runs only on the explicit Look up action. The Scan
button is shown only where the device can scan at all, the camera lives in the app target so the UI
package stays free of any camera framework, and the scanner never sees anything but the code: no
image is stored, and a code of the wrong length or with a wrong check digit is simply skipped while
scanning goes on.

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
