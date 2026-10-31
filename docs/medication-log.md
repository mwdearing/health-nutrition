# Medication log

Status: in progress. The rules and the store exist; there are no screens yet.

The medication log keeps the medications a person names and the doses they type. The person
names each medication and types every dose field. The log never suggests, checks or changes a
dose, and it holds no list of drugs, dose ranges, titration steps or advice.

## Rules

- **Units.** A medication is measured in mg, mcg, mL or units. A dose uses the medication's current
  unit.
- **Site.** A dose may carry an optional injection site that the person types. It is at most 40
  characters, has no whitespace at either end and no line break. It is kept with the dose only:
  it is never used in schedules, trends or charts, and the log's day, last-dose and schedule rules
  never read it.
- **Name.** A name is required, has no whitespace (space, tab or line break) at either end and no
  line break inside, and is at most 60 characters. Names are unique ignoring case across all
  medications, archived ones included.
- **Schedule.** A medication may have no schedule, or a schedule of every 1 to 28 days. An
  archived medication keeps its doses and its schedule, but reports no status until it is unarchived.
- **Amount.** A dose amount is above 0, at most 1000, and has at most three decimals. Amounts are
  stored as exact decimal text, never as binary floating point.
- **Time zone.** Each dose records the time zone it was taken in. A dose's day is the local day
  of its own time zone, so a dose keeps its day when the phone travels.
- **Note.** A note is optional. When present it is not blank and is at most 200 characters.
- **Schedule arithmetic.** The schedule counts calendar days. A status is one of: not scheduled,
  no dose yet, upcoming (with the due day), due today, or overdue by a number of whole days.

A refused save writes nothing. Saving a medication or dose with an existing id replaces it.
Removing a medication also removes its doses. Changing a medication's unit leaves every dose
already logged in its old unit.

## Store

The medications and doses are kept in their own store file, `medications.store`, separate from
the journal. The file uses a versioned schema (version 1.0.0) with a migration plan that lists
that first version, and it opens without CloudKit. The site was added to version 1.0.0 in place,
not as a second version: no app code opens the store file yet (the app wiring lands with the
screens), so no released build has created one in the older shape.

A row that cannot be read, or that fails the same checks as a save, fails the whole read. The
log never skips a damaged row and shows the rest as if nothing were wrong.

Erase all data will delete the medication rows, then replace the store file and its `-wal` and
`-shm` files with an empty one, as the other stores do. The store can already erase itself, but
it is not yet wired into Erase all data; that wiring lands with the screens.

## Not in this slice

- No screens and no app wiring.
- Not in the journal export yet.
- No reminders yet.
