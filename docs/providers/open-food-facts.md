# Open Food Facts: data source determination

Status: Accepted for user-submitted name search only; barcodes no longer use Open Food Facts (catalog-only, #863) (amended 2026-10-13; search moved to the Open Food Facts search service 2026-10-14). Terms review date: 2027-04-02.

## What is used

The app reads one product at a time from the Open Food Facts API v3
(`/api/v3/product/<barcode>`) after the user scans or types a barcode. The request
asks only for the fields it needs: code, product name, brands, serving size,
serving quantity, the basis of the nutrition data, the nutriments and the last
modification time and the unit of the product quantity. The use is read-only; the app never writes to Open Food Facts.

Nutrient amounts are decoded as decimal numbers. Open Food Facts normalizes the
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
codes and hands its raw payload to the UI package, which applies the same rule the field applies to
typed digits: 8, 12 or 13 digits with a correct GS1 check digit, anything else ignored. A UPC-E
payload is the one exception: its eight printed digits stand for a GTIN-12 with zeros left out, so
they pass the EAN-8 check while naming a different number, and the payload is expanded to its
GTIN-12 first (`ScannedBarcode.expandUPCE`). A payload that does not expand is skipped rather than
looked up as the eight digits it shows. The first payload that passes fills the barcode field and
closes the scanner; no request is sent while the camera is open, and the lookup still runs only on
the explicit Look up action. Scanning a different code also clears the form the way a lookup that
finds nothing does, so the name, nutrients and attribution of the product looked up before are never
left standing under a code the source has not been asked about. The Scan and Look up buttons are
separate controls with independent hit areas, so one tap cannot do both. The Scan button is shown
only where the device can scan at all, the
camera lives in the app target so the UI package stays free of any camera framework, and the
scanner never sees anything but the code: no image is stored. If the camera becomes unavailable
while the sheet is open, for instance when permission is denied, the sheet shows the reason and a
Close button and asks once: it does not keep retrying while the notice is on screen.

## Licenses

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
- Name search uses the Open Food Facts full-text search service
  (`https://search.openfoodfacts.org/search`), which the Open Food Facts API
  documentation names as the place for full-text search. The legacy
  `/cgi/search.pl` endpoint is no longer used: it orders loose keyword matches by
  worldwide scan count, so a common word returned popular products that do not
  have the word in their name. The search service orders by how well the name
  matches. No limit is published for the search service itself, so the app keeps
  to the limit documented for search requests: one request per explicit submit by
  the person (no search-as-you-type, no autocomplete, no background or bulk
  queries), at most 6 searches in any rolling 60 seconds against a documented
  limit of 10 per minute, one page of 50 results of which at most 20 are shown
  after the name filter below, and the same User-Agent as lookups. Supplements are not searched here.
- Only the typed words (2 to 80 characters) are sent, with the page size and the
  list of fields wanted: no country, sort order or identifier, and no language
  except that words typed in Thai script also send `langs=th`, because Thai names
  are indexed only under Thai (read from the typed words, never from the device;
  French, Chinese, Japanese and Korean names were found without it). The
  service reads its query as a query language, so the client writes a single `&`
  as the word "and", replaces every other syntax character
  (`+ - && | ! ( ) { } [ ] ^ " ~ * ? : \ / < > =`) with a space, and lowercases
  the operator words `AND`, `OR`, `NOT` and `TO`. The 80-character cap applies
  after that. What is sent can only be a list of words to match; text with no
  letters or digits sends nothing.
- A product Open Food Facts marks obsolete (discontinued or withdrawn) is left
  out, because its facts may be stale; the flag is requested with the results and
  checked on the device, so nothing extra is added to the query.
- A result with no product name is left out, and a result with the same name and
  brand as an earlier one is left out, because neither can be told apart in a list
  of names. The service also matches on category, label and names in other
  languages, so a result is kept only when its name, or its name and brand
  together, show every typed word; results with the words in the name come first.
  Both sides are written the same way first: case and accents folded, full-width
  letters and digits narrowed, ligatures spelled out ("Œufs" and "oeufs"),
  apostrophes removed inside words ("Kellogg's" and "Kelloggs"), and "&" read as
  "and" (a typed "&" is sent as "and"). A typed word is shown when it begins a
  shown word ("choc" and "Chocolate"), or when a singular of it is a whole shown
  word or the singular of one ("loaves" and "Loaf", "berries" and "Berry"); "-es" is
  only taken off after s, x, z, ch, sh or o, and those singular guesses are only
  compared as whole words, so "ham" does not match
  "Champagne", "milk" does not match "Millet" and "cookies" does not match
  "Cooking". Words in scripts written without spaces (Chinese, Japanese, Thai and
  similar) are matched anywhere in the name. Text with no letters or digits sends
  nothing, and a reply entry of the wrong shape is skipped without losing the
  rest of the reply. The search index has per-100 figures but no serving, and in
  practice no unit field, so whether a result is per 100 g or per 100 mL is read
  from its pack quantity ("1 gallon", "400 g", "32 fl oz (946 ml)"): only masses
  give per 100 g, only volumes per 100 mL, and a mix or no unit leaves it "per
  100 g or mL". That basis is scaled to an amount only when every logged component
  is a weight (per 100 g) or every one is a volume (per 100 mL), and the amounts
  are summed; a count such as a scoop, a mix of weight and volume, or a negative
  amount still cannot be scaled and stays unknown. A result opens with no
  serving filled in. Opening a result sends nothing: the form is filled from the
  search reply. The owner decided on 2026-10-14 that a picked result's barcode is
  not sent to Open Food Facts to read the fuller record; scanning or typing a
  barcode remains the way to get the serving.
- The results screen shows the attribution text on every result with a link to
  the license and source, and states that the search words are sent to Open Food
  Facts.
- Submitting the same words again within those 60 seconds sends nothing and does
  not count toward the 6: the reply already received is shown again, and a submit
  made while that request is still running waits for its reply. The reply is held
  in memory only, for at most 60 seconds, and only when it held results or none; a
  failed or refused search is sent again when the person retries. When the cap is
  reached the screen says there were too many searches and how long to wait.

## Etiquette and limits

- Every request sends a User-Agent of the form
  `HealthNutrition/<version> (https://github.com/mwdearing/health-nutrition/issues)`.
- Open Food Facts publishes 15 product reads and 10 searches per minute per user
  for apps. The client limits itself to 10 lookups in any rolling 60 seconds and answers further calls
  with a rate-limited outcome without sending a request. The window uses a monotonic
  clock. HTTP 429 and 503 are also reported as rate limited, using the Retry-After
  header (seconds or HTTP-date) when present. For name search, a 503 without a
  Retry-After header is reported as the source being unavailable: the search
  endpoint answers that way when it is down or shedding load, and no wait is known.
- A barcode is checked locally first (digits only, EAN-8, UPC-A or EAN-13, correct
  check digit); an invalid barcode never causes a request.
- Tests use a stub transport and fixtures with invented values. The staging server
  (`world.openfoodfacts.net`) is for manual checks, never production data. Its
  basic-auth credentials are published in the Open Food Facts documentation; the
  caller injects the header value at manual-test time and it is never committed.

## Review

Re-read the Open Food Facts terms of use and the API documentation by 2027-04-02,
or sooner if they change, and update this note.
