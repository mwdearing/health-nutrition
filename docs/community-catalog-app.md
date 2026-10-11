# Community catalog in the app

The app uses the community catalog in two places: a barcode that Open Food Facts does not know is looked up there, and a label you capture and save is sent to it. This page states the rules the app follows. The client and its endpoints are in [the community client](community-client.md). What a person sees in Settings and what stays on the phone is in [accounts](accounts.md).

## Looking a barcode up

- Open Food Facts is asked first, as before. The catalog is asked only when Open Food Facts finds nothing for the barcode, and only for a person who is signed in. A signed-out person makes no catalog call.
- A catalog label is shown with the values it came with and a line that says how many people agree on them. A verified label reads "Verified by the community: N people agree on these values." An unverified one reads "Shared by the community, not yet verified: N people agree." That line is the only verified mark: a catalog value never reads as if Open Food Facts gave it.
- When the catalog has more than one basis for a barcode, the app shows per 100 g first, then per 100 mL, then per serving.
- A catalog failure, such as no connection or a server error, reads as "No product found for that barcode." It is never shown as a failed lookup.
- The catalog's rate limit is not shown: a catalog failure is always "not found" to the person.

## Sharing a saved label

A label is sent only after the entry is saved, and only when every condition below holds. The conditions are checked when the entry is saved, not when the label was captured.

- Sharing is on in Settings, Account, at that moment.
- The values came from the label capture itself. A Library entry, a repeat of an entry, a recipe and a barcode lookup are never sent.
- The entry is a food or a drink. A supplement is never sent.
- The barcode passes the shape and check-digit test (8, 12 or 13 digits).
- The name is not blank.
- At least three of the nine standard nutrients are stated as amounts. A bound such as "less than 1 g" and a value marked as not applicable do not count.
- A per-serving label states its serving size.

What is sent: the barcode, the basis (per 100 g, per 100 mL or per serving), the serving text, the product name, the brand if you gave one, and the nutrient amounts in the catalog's units (energy in kcal, sodium in mg, the rest in g). Nothing else is sent. The amount you ate, the time, the meal, notes, the entry's identifier, your account identifier and any photo are not part of the upload, and a test checks the list of fields.

## When an upload fails

The upload runs in its own task after the save has finished. The app does not show its result, does not retry it, and does not change the save if it fails. A label whose upload fails is not sent again, so a label saved while the phone is offline is not shared.

## Not in this version

- No retry or offline queue.
- No verified badge other than the attribution line.
