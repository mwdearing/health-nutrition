# USDA FoodData Central: name search source

Status: Accepted for name search (2026-10-17). Data is public domain (U.S. government work); the app still shows the source line on every USDA row, as USDA asks.

- Endpoint: `https://api.nal.usda.gov/fdc/v1/foods/search`, data types Foundation, SR Legacy and Branded.
- Key: `USDA_FDC_API_KEY`, a GitHub repo secret injected into the build's Info.plist by `signed-beta.yml`. It is sent in the `X-Api-Key` header and never in the URL, a log line or a stored value. Without a key, name search is Open Food Facts only.
- Nutrients come from `nutrientId` (1008 energy, 1003 protein, 1005 carbohydrates, 2000 sugars, 1004 fat, 1258 saturated fat, 1079 fiber, 1093 sodium). The legacy `nutrientNumber` is never read. A nutrient the record lacks stays unknown, never zero.
- Basis: values are per 100 g. Gram servings come from Branded records only.
- Limits: the client refuses replies over 1 MiB and queries over 80 characters, and reads `Retry-After` as seconds or an HTTP date.
- Barcodes: USDA has no barcode endpoint. Rows carry no barcode, so a picked USDA row is stored with none.
- Privacy: the typed words go to USDA when the build carries a key; see [PRIVACY.md](../../PRIVACY.md) and [privacy-manifest](../privacy-manifest.md).
- Open: a Retry-After on a live 429 has not been observed yet; the header parse is unit-tested only.
