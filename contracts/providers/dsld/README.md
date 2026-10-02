# NIH DSLD Label Fixtures

## Purpose

These are recorded API responses from the NIH Dietary Supplement Label Database (DSLD),
used as test fixtures for the nutrition app's DSLD import adapter. They allow development
and testing against real API response structures without requiring live API access.

## Source

All fixtures come from the public NIH DSLD API:

- Version info: `https://api.ods.od.nih.gov/dsld/version`
- Search: `https://api.ods.od.nih.gov/dsld/v9/search-filter?q=<term>&size=10`
- Label detail: `https://api.ods.od.nih.gov/dsld/v9/label/<id>`

## License

The DSLD data is released under the [CC0 1.0 Universal license](https://creativecommons.org/publicdomain/zero/1.0/).
These fixture files are derived from that public domain data.

## Selection Method

Fixtures are selected using a fixed set of 10 search terms (not by brand or product name):

1. `magnesium citrate`
2. `creatine monohydrate`
3. `vitamin D3`
4. `proprietary blend`
5. `fish oil`
6. `multivitamin`
7. `zinc gluconate`
8. `probiotic`
9. `melatonin`
10. `methylcobalamin`

For each term, the first label returned with non-empty `ingredientRows` is saved.
At most 2 extra labels may be added if a coverage requirement is not met by the
first 10 picks. The result is 10–12 label fixtures total.

## Coverage Requirements

The selection is validated against these coverage items:

- At least one off-market label (`offMarket == 1`)
- At least one row with quantity unit "IU"
- At least one form name containing "Citrate"
- At least one "Proprietary Blend" row or a row with `nestedRows`
- At least one creatine row

## Exclusions

Product images and PDF documents are deliberately excluded from these fixtures.
Including them would require a separate licensing review, as they may carry
different usage restrictions than the label data itself.

## Disclaimer

Inclusion of a product label in these fixtures does not constitute an endorsement
of that product by the NIH, the Office of Dietary Supplements, or the app developers.
These are API response snapshots for testing purposes only.

## Re-recording

To re-record all fixtures:

1. Search each term via the search-filter endpoint above.
2. For each hit, fetch the label via the label endpoint.
3. Save the JSON response as `fixtures/labels/<id>.json`.
4. Save the version info as `fixtures/version.json`.
5. Update `MANIFEST.json` with current hashes and metadata.

All files must be saved as raw JSON bytes (no pretty-printing or edits to the API response).
