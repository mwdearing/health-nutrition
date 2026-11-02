# Medication log

Status: the list, add, log and archive screens exist. Settings has the switch (off by default), and the
Library shows a Medication log row once it is on. Not yet: history editing, the Today tile, export and the
weight trend.

The medication log keeps the medications a person names and the doses they type. The person
names each medication and types every dose field. The log never suggests, checks or changes a
dose, and it holds no list of drugs, dose ranges, titration steps or advice.

## Screens

- **Settings switch.** Settings > Units and logging has a Medication log switch. It is off by default.
  Turning it off hides the log and keeps the data.
- **Library row.** While the switch is on, the Library shows a Medication log row next to My supplements.
- **List.** Each active medication shows its name, unit and schedule, then these lines:
  - "Last dose" with the amount, unit, day and time of the latest dose, or "No dose logged yet";
  - days since the last dose: "Today", "1 day since" or "N days since". A dose whose own day is after
    today on this device (logged further east, then read after travelling west) has no days-since line;
  - the schedule standing: "Next by your schedule: <day>", "Due today", "Overdue by 1 day" or
    "Overdue by N days". A medication with no schedule, or with no dose yet, shows no standing line.
    A dose whose own day is after today on this device has no standing line either, as it has no
    days-since line.
  - Archived medications sit in an Archived section, shown only when there is one.
- **Add.** Add medication opens a sheet with a name, a unit (mg, mcg, mL or units) and an optional
  "Every how many days" field from 1 to 28. An empty field means no schedule.
- **Log with Undo.** Tapping a medication opens Log a dose: an amount (decimal pad), a date and time that
  start at now and cannot go past it, an optional injection site and an optional note. After a save the
  screen offers Undo, which removes only that dose. If the removal fails, Undo stays offered so it can be
  tried again; Erase all data and a restore withdraw it.
- **Amounts.** Amounts read as stored, with a comma between thousands: "1,000 mg", "2.5 mg".
- **Archive.** Swiping a row archives it, and swiping an archived row unarchives it. Archiving keeps the
  medication's doses and schedule.

The injection site is saved with the dose and is never shown in the list, trends or charts.

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
that first version, and it opens without CloudKit. Version 1.0.0 was amended in place before the
app opened the file, so no released build has created it in an older shape. Any later change to
the schema needs a new schema version and a migration stage.

The app opens `medications.store` with the other stores. When the file cannot be opened, the app
still starts, and the store tries the open again on each read. The Medication log then shows
"Could not read the medication log." and offers **Clear the medication log**. After the person
confirms, clearing removes the file and its `-wal` and `-shm` files without a checkpoint, and opens
an empty log. Erase all data does the same. A damaged row gets the same offer. Nothing removes the
file without one of those actions.

A row that cannot be read, or that fails the same checks as a save, fails the whole read. The
log never skips a damaged row and shows the rest as if nothing were wrong.

Erase all data erases `medications.store` last. It deletes the medication rows, then replaces the
store file and its `-wal` and `-shm` files with an empty one, as the other stores do. The Medication
log switch is reset by the erase too (see [Erase all data](erase-all-data.md)). When the file could
not be opened, the erase replaces it without a checkpoint, and the store opens an empty log.

## Not yet

- History editing (a later slice).
- The Today tile (a later slice).
- Export.
- The weight trend markers.
