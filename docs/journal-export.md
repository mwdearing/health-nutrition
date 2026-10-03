# Journal export

## What it is
A single JSON file with everything the journal holds on this device: every intake with **all** of its
revisions, the tombstones of deleted intakes, and the favorite templates. The app builds it locally and
encodes it with `JSONEncoder` using sorted keys and ISO-8601 dates, so the same journal always encodes to
the same bytes.

The contract lives in the repository next to the code:
- `contracts/journal-export/v1.schema.json` - JSON Schema, draft 2020-12, `additionalProperties: false` at the top level and on every object it defines.
- `contracts/journal-export/example.v1.json` - a small synthetic document that validates against the schema. The copies of both files in `ios/NutritionCore/Tests/NutritionJournalExportTests/Contracts/` are the same files; tests decode them, so Swift and the schema cannot drift apart.

The document is built by `JournalExporter.makeExport(store:favorites:appVersion:exportedAt:)` and written
by `JournalExporter.encode(_:)`. The app version string is injected; the module has no build information of
its own.

## Fields
| Field | Meaning |
|---|---|
| `schema_version` | Version of the schema this document follows. This build writes `1`. |
| `exported_at` | When the export was made, ISO-8601 in UTC. |
| `app_version` | Version of the app that wrote the file. |
| `intakes` | Active intakes, sorted by id. Each one carries its time zone, category, meal, note, current revision number and every revision. |
| `tombstones` | Deleted intakes with their last revision number, sorted by `intake_id`. A later import needs them to retract an entry instead of leaving it behind. |
| `favorites` | Favorite templates as stored, sorted by id. A favorite is a copy, never a link to an intake. |

Inside a revision, `components` carry `component_id`, `name`, `amount`, `unit` and `value_state`. Amounts
are **exact decimal strings** in the POSIX format (`"37.5"`, `"250"`), never JSON numbers, because a binary
float would quietly change the value. A missing amount is `"amount": null` with `"value_state": "unknown"`
and is never written as `0`. `provenance` repeats the immutable product snapshot a revision points at, so
the export says where the amounts came from.

## Versioning rule
`schema_version` never changes shape. Adding a field, removing one, renaming one or changing what a field
means requires a **new schema version** (a new `v2.schema.json`) and a new `currentSchemaVersion` in
`JournalExport`. Readers of version 1 keep working, because a reader that does not know a field can ignore
it and version 1 keeps rejecting unknown fields through `additionalProperties: false`.

## Privacy
- The export is **local and user-initiated**. Nothing is uploaded, and no network call is involved: the
  module imports no networking framework, and the file is written into the app's temporary directory.
- Data leaves the app only through the system share sheet or a file exporter the person opens, and only
  because they asked. Nothing is shared on a timer or in the background.
- Deleting the app deletes its store; the temporary export file is removed when the person shares it or
  clears the export from the Connections and privacy screen.
- Apple Health and HealthRelay are listed on that screen as **shown but disabled**: the switches cannot be
  turned on until those work packages ship, so the screen never implies that data is already leaving the
  device.

## Entry point
The Library screen is the only way in: `LibraryView(connections:)` shows a "Connections and privacy" row
that pushes `ConnectionsPrivacyView`. Today and Add intake have no entry to it, on purpose.

## Follow-ups
- No import path yet. The tombstones and revision history are exported so an importer can be added later
  without a format change.
- The app target does not exist yet, so `ConnectionsPrivacyViewModel` injects a placeholder version string
  until the shell can pass the real one.