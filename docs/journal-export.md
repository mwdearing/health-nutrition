# Journal export

## What it is
A single JSON file with everything the journal holds on this device: every intake with **all** of its
revisions, the tombstones of deleted intakes, and the favorite templates. The app builds it locally and
encodes it with `JSONEncoder` using sorted keys and ISO-8601 dates in UTC, so the same journal always encodes
to the same bytes. Dates carry **six fractional digits**, so a timestamp survives the round trip exactly: a
three-digit fraction would round a `Date` to the nearest millisecond and could move two entries onto the same
instant. Foundation's formatters only ever write three, so the module formats the whole seconds with one
cached `DateFormatter` per run and writes the fraction itself, reading it back the same way. Millisecond and
whole-second dates written by earlier builds still import. Favorites are written in id order, so two exports
of the same favorites are the same document.

The contract lives in the repository next to the code:
- `contracts/journal-export/v1.schema.json` - JSON Schema, draft 2020-12, `additionalProperties: false` at the top level and on every object it defines.
- `contracts/journal-export/example.v1.json` - a small synthetic document that validates against the schema.

Those two files are the canonical ones. SwiftPM can only bundle resources that live inside a target, so copies
sit in `ios/NutritionCore/Tests/NutritionJournalExportTests/Contracts/`; a test compares the two locations
byte for byte, so a contract change without a fresh copy fails the build instead of passing against a stale
contract.

The document is built by `JournalExporter.makeExport(store:favorites:appVersion:exportedAt:)` and written
by `JournalExporter.encode(_:)`. The app version string is injected; the module has no build information of
its own. The build reads the journal in one pass through `JournalSnapshotSource.readJournalSnapshot()`, which
holds the store's write lock while it fetches active intakes, their revisions and the tombstones. Without
that, an entry deleted between two separate reads would appear in neither list and would silently vanish from
the backup.

`JournalExporter.decode(_:)` reads a document back and refuses any `schema_version` other than
`currentSchemaVersion` with `JournalExportError.unsupportedSchemaVersion`, because a reader that does not
know a newer version's semantics would otherwise hand back a document with fields it silently ignored.

## Importing

A file written by the export above can be read back into an empty journal:

```swift
let summary = try JournalImporter.importExport(data, into: store, favorites: favorites)
```

`JournalImporter.importExport(_:into:favorites:)` reads the whole file, checks it, and only then writes.
It returns a `JournalImportSummary` counting the intakes, revisions, tombstones, favorites and product
snapshots it wrote, and it throws `JournalImportError` instead of writing part of a file:

| Case | Meaning |
|---|---|
| `unsupportedVersion` | The document declares a `schema_version` this build does not read. The version is read from the raw JSON before anything else, so a file from a newer build is refused as such even when its other fields would not decode. A file that spells the same version as `"1"` rather than `1` is accepted. |
| `notEmpty` | The store already holds intakes, active or deleted. There is no merge in this version: one journal is restored into an empty one. A tombstone is an intake row too, so a journal that already has one is not empty either. |
| `malformed` | The bytes are not a journal export: not JSON, or not the shape the schema describes. |
| `corrupt` | The file is a version 1 export that cannot be restored as it stands. |

What a restore writes:
- **Every intake with every one of its revisions, in order.** Ids, `occurred_at`, `created_at`, the time
  zone, the meal, the note, the revision numbers and the current revision are the file's, so an import
  renumbers nothing and moves no entry onto another instant. An intake whose revisions are not `1` to
  `current_revision` in order is `corrupt`: a history that reads as if time ran backwards is not one.
- **Deleted intakes as tombstones.** A tombstone carries the id, the revision it was deleted at, when and
  where, which is all a retraction needs. A deleted entry is never listed or repeated, so its category is
  not in the file and the restored row carries an empty one rather than an invented value. It has no
  revision row either, because the file does not carry the amounts it held when it was deleted.
- **Product snapshots.** Every snapshot the entries and favorites refer to is written back, so a restored
  entry needs no catalog lookup to be shown or repeated. A revision that names a snapshot nothing defines
  is `corrupt`: the amounts would have to come from somewhere, and inventing them is what this refuses.
- **Favorites**, as the templates they are, with their decimal text kept exactly as it was written.

Amounts are read as exact decimal text and stored as `Decimal`, never as a binary float. A component whose
`value_state` is `unknown` is **refused** with `corrupt`: the journal keeps a missing amount as a
not-a-number decimal and refuses to write one, so restoring it as `0` would turn "not known" into "none".
The export a real journal writes never holds one, so this only happens for a hand-edited file.

**No delivery work is queued.** An import writes no projection and no outbox operation: a restored entry is
history the destinations were already sent once, and re-sending yesterday's breakfast because a phone was
replaced would be a delivery nobody asked for. `create`, `edit` and `delete` are untouched and still queue
what they always did, so an edit made after a restore is delivered normally.

**One transaction, two files.** The whole document is read and checked before the first row is written, so
a file that is refused - malformed, from a newer version, or internally inconsistent - changes nothing at
all. The journal and the favorites then live in two separate store files, so their two writes cannot be one
transaction; the journal write is one `save()` covering every row and the favorites write is one `save()`
covering every favorite. The favorites go **first**, because that is the order that keeps a retry possible:
a journal write that fails leaves an empty journal and nothing to undo, while the other order would leave a
restored journal that refuses the next attempt because it is no longer empty. Importing the same file twice
therefore only ever writes the same rows again.

The action on the Connections and privacy screen is a file picker (`fileImporter`, JSON only) that reads the
bytes and hands them to the model, which shows the summary line or the reason the file was refused. Nothing
is sent anywhere: the file was already on the device, or somewhere the person opened it from.

## Fields
| Field | Meaning |
|---|---|
| `schema_version` | Version of the schema this document follows. This build writes `1`. |
| `exported_at` | When the export was made, ISO-8601 in UTC. |
| `app_version` | Version of the app that wrote the file. |
| `intakes` | Active intakes, sorted by id. Each one carries its time zone, category, meal, note, current revision number and every revision. |
| `tombstones` | Deleted intakes with their last revision number, sorted by `intake_id`. A later import needs them to retract an entry instead of leaving it behind. |
| `favorites` | Favorite templates as stored, sorted by id. A favorite is a copy, never a link to an intake. |
| `products` | Every product snapshot a revision or a favorite refers to, sorted by `snapshot_id`. |

Inside a revision, `components` carry `component_id`, `name`, `amount`, `unit` and `value_state`. Amounts
are **exact decimal strings** in the POSIX format (`"37.5"`, `"250"`), never JSON numbers, because a binary
float would quietly change the value. A missing amount is `"amount": null` with `"value_state": "unknown"`
and is never written as `0`. The schema ties the two together with a `oneOf`, so `"amount": null` with
`"value_state": "known"` does not validate either. `provenance` repeats the immutable product snapshot a
revision points at, so the export says where the amounts came from.

`products` is what lets a favorite outlive the intakes it was made from. Once those intakes are deleted only
tombstones remain, so without this list the favorite would keep a `product_snapshot_id` that nothing in the
document defines, and repeating it after a restore would need the catalog. Every referenced snapshot travels
with the document; an export whose reference cannot be resolved fails loudly with
`JournalExportError.missingProductSnapshot` rather than writing a dangling id. A snapshot is immutable, so one
already resolved is reused instead of being fetched again for every revision that names it.

## Nulls, and what the export refuses to write
- Every key a `required` list names is always present. A value that is not known is written as an explicit
  JSON `null` - `meal`, `note`, `product_snapshot_id`, `provenance`, `brand`, `barcode` and an unknown
  `amount` - because the schema marks them required-but-nullable and a missing key does not validate.
- A favorite's stored amount text is checked against the schema's decimal pattern before it is written. The
  favorites store accepts text such as `1.2.3`, which the pattern does not allow, so the export fails with
  `JournalExportError.malformedFavoriteAmount` rather than writing a backup no reader could use.
- A stored intake whose lifecycle value is neither `active` nor `deleted` is corrupt, so the snapshot read
  fails with `JournalError.corruptRecord` instead of treating the row as live data.

## Versioning rule
`schema_version` never changes shape. Adding a field, removing one, renaming one or changing what a field
means requires a **new schema version** (a new `v2.schema.json`) and a new `currentSchemaVersion` in
`JournalExport`. Readers of version 1 keep working, because a reader that does not know a field can ignore
it and version 1 keeps rejecting unknown fields through `additionalProperties: false`. This build writes only
version 1 and reads only version 1; `decode(_:)` refuses anything else by value rather than by shape, so a
version 2 file is never half-understood.

## Privacy
- The export is **local and user-initiated**. Nothing is uploaded, and no network call is involved: the
  module imports no networking framework, and the file is written into the app's temporary directory.
- The file is written complete-only (`[.atomic, .completeFileProtection]`), so the journal is unreadable
  while the device is locked, and written in one step so no half-written copy can be shared.
- Data leaves the app only through the system share sheet or a file exporter the person opens, and only
  because they asked. Nothing is shared on a timer or in the background.
- Deleting the app deletes its store; the temporary export file is removed from disk when the export is
  cleared, when the screen is left (`onDisappear` calls `clearExport()`), when an export attempt fails, and
  when a new export replaces it in another second. At most one copy of the journal is ever left in the
  temporary directory.
- Apple Health and HealthRelay are listed on that screen as **shown but disabled**: the switches cannot be
  turned on until those work packages ship, so the screen never implies that data is already leaving the
  device.

## Entry point
The Library screen is the only way in: `LibraryView(connections:)` shows a "Connections and privacy" row
that pushes `ConnectionsPrivacyView`. Today and Add intake have no entry to it, on purpose.

## Follow-ups
- No merge. An import restores into an empty journal only; a later version may add a merge, and the
  revision history and tombstones in the document are what it would need.
- A restored product snapshot states no nutrient values, because the document does not carry them. The
  amounts a restored entry shows come from the snapshot's identity as before; the catalog supplies the
  values again when something needs them.
- The app target does not exist yet, so `ConnectionsPrivacyViewModel` injects a placeholder version string
  until the shell can pass the real one.