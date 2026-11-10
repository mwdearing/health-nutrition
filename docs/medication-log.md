# Medication log

Status: the list, add, log, archive and history screens and the Today tile exist, and the log is in the journal export. Settings has the switch (off by default), and the
Library shows a Medication log row once it is on. Dose days show on the weight chart while the log is on.

The medication log keeps the medications a person names and the doses they type. The person
names each medication and types every dose field. The log never suggests, checks or changes a
dose, and it holds no list of drugs, dose ranges, titration steps or advice.

## Screens

- **Settings switch.** Settings > Units and logging has a Medication log switch. It is off by default.
  Turning it off hides the log and keeps the data.
- **Library row.** While the switch is on, the Library shows a Medication log row next to My supplements.
- **Today.** While the switch is on, the Medications tile on Today shows each active medication's standing (see
  [today-screen.md](today-screen.md)).
- **List.** Each active medication shows its name, unit and schedule, then these lines:
  - "Last dose" with the amount, unit, day and time of the latest dose, or "No dose logged yet";
  - days since the last dose: "Today", "1 day since" or "N days since". A dose whose own day is after
    today on this device (logged further east, then read after traveling west) has no days-since line;
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
- **History.** Each medication, archived ones too, has a history: its doses newest first, each read in
  the zone it was logged in, with its amount and note. The site is never shown, and an edit keeps the
  site as it was stored. A dose can be edited (amount, time or note; a changed time takes the device's
  zone) or deleted after a confirmation. A time left within the same minute keeps the logged time and
  zone. Back on the list, a changed history withdraws Undo.

The injection site is saved with the dose and is never shown in the list, trends or charts.

## Notice

The log states what it is: "This log keeps what you enter. It does not give medical advice or suggest doses." The text is one constant in the app and shows as a footnote on the
Medication log screen, under the list, and beside the Settings switch.

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

## Reminders

A medication that is active and keeps a schedule can have a reminder. It is off by default and is set per
medication, on the medication's history screen, under **Reminder**: the switch **Remind me on due days**, and
a time of day (09:00 until the person changes it) while the switch is on.

- **What triggers it.** One local notification for the day the schedule next asks for a dose (the last
  dose's day plus the schedule's days), at the time picked. Nothing is set when there is no dose yet, when
  the dose's day cannot be read, when that day has passed, when the picked time is already past today, for
  an archived medication, for one with no schedule, or while the Medication log switch is off in Settings.
  Logging, undoing, editing or deleting a dose, adding or archiving a medication, switching the log on or
  off, opening the app and returning to it all set the notification again.
- **The text.** The title is "Medication log" and the body is "A dose in your medication log is due today."
  The notification does not name the medication or a dose, and gives no advice.
- **The footer** under the switch says what is pending, or why nothing is.
- **Permission.** Switching a reminder on asks for notification permission only when it has not been
  decided. Opening the app never asks, and while the choice is undecided it leaves the settings alone. If
  notifications are turned off for the app, every medication reminder switches off and says so.
- **Unreadable log.** If the medication log cannot be read, nothing stays pending, the settings are kept and the
  screen says reminders are paused until it can be read.
- **At most 20** medication reminders are pending at once, soonest first.
- **Switching off removes it.** Switching a reminder off removes its pending and its already delivered
  notification; switching the log off removes the pending ones and keeps the settings.
- **Erase all data removes them**: the settings and every pending or delivered request with the
  `medication-reminder-` prefix, whether or not its medication still has a setting. The erase waits for the
  removal before its check, and names "medication reminders" if one is still there or the removal could not be confirmed.
- Stored on this device only (`display.reminders.medication`). Not exported.

## Store

The medications and doses are kept in their own store file, `medications.store`, separate from
the journal. The file uses a versioned schema (version 1.0.0) with a migration plan that lists
that first version, and it opens without CloudKit. Version 1.0.0 was amended in place before the
app opened the file, so no released build has created it in an older shape. Any later change to
the schema needs a new schema version and a migration stage.

The app opens `medications.store` with the other stores. When the file cannot be opened, the app
still starts, and the store tries the open again on each read. The Medication log then shows
"Could not read the medication log." and offers **Clear the medication log**. After the person
confirms, clearing reads the log again first; a log that reads now is kept, because a read can fail
for a passing reason such as a locked or busy file, and the screen says "The medication log can be read
again, so nothing was cleared." A log that still cannot be read is cleared:
clearing removes the file and its `-wal` and `-shm` files without a checkpoint, and opens
an empty log. It does so only when SQLite finds the file damaged: it cannot be read as a
database, or its integrity check reports a fault. A file that fails to open for another reason,
such as a locked or busy file, is kept, and the clear says it could not clear the log. A failed
clear reads the log again, so the screen shows what the file now holds. Erase all data does the same.
When the log reads after a failed clear, as it does when the erase removed the rows before it failed,
the Medication log says "The clear did not finish. The log shows what this device holds now." instead.
A row that fails the log's own checks, in a file SQLite finds healthy, gets the same offer, and
clearing removes it: the erase deletes rows without reading them back through those checks, and then
replaces the file as usual. A row the store cannot load at all, such as one written outside the app with
a required field missing, is removed too: when the rows cannot be deleted, the erase still replaces the
file, checkpoint first, and the replacement removes them. Nothing removes the file without one of those actions.

A kept file can leave the log unreadable with a clear that keeps failing. That is the intended result:
a locked or busy file reads again on a later try, and removing a file that SQLite does not find
damaged could delete a log that can still be read.

A file that the device cannot decrypt is not judged damaged. The store files use the system's default
data protection, and while a protected file's key is unavailable the system refuses the read itself,
which SQLite reports as an I/O or open error, never as a file that is not a database or a corrupt
one, because SQLite is never handed the encrypted bytes. SQLite reports a short read as an I/O error,
which is not counted as damage. A short read that surfaces as a failed integrity check would be,
and that case has not been checked on a device. Both the clear and Erase all data also run
only from a confirmation on screen, so the phone is unlocked when they run. This rests on how the
system documents data protection; it has not been checked on a device.

A row that cannot be read, or that fails the same checks as a save, fails the whole read. The
log never skips a damaged row and shows the rest as if nothing were wrong.

Erase all data erases `medications.store` last. It deletes the medication rows, then replaces the
store file and its `-wal` and `-shm` files with an empty one, as the other stores do. The Medication
log switch is reset by the erase too (see [Erase all data](erase-all-data.md)). When the file cannot
be opened, its rows cannot be deleted or its checkpoint fails, the erase replaces it without a
checkpoint only when SQLite finds it damaged, as above, and the store opens an empty log. Otherwise
the file is kept and the erase reports the failure.

## Export and restore

The journal export (version 9) carries every medication, archived ones included, and every dose. Restoring an
export adds the medications and doses in the file that are not on this device, including ones deleted since the file
was made: a restore keeps no record of deletions. It never replaces a medication or dose the device holds, and a
file medication whose name or id the device holds under another name is left out with its doses. The restore screen
says so under its button. Detail: [journal-export.md](journal-export.md).
