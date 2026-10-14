# My supplements

Status: Current. Reviewed whenever favorites, the journal's day rule or erase change.

A list of the supplements a person takes, with the times of day and days of the week they take each
one, and a one-tap **Taken** that logs it. Reached from the Library ("My supplements").

- **Items are favorites.** The amounts, unit and product snapshot (the label the item was logged from)
  come from the favorite, so **Taken** logs exactly what the favorite copied: a new entry now, in the
  current time zone, through the same repeater the Library uses. It is an ordinary entry, so once Apple
  Health is connected it is written there like any other ([HealthKit writer](healthkit-writer.md)). The
  list never states, suggests or changes an amount.
- **Adding.** The picker offers favorites not on the list (supplements first), then supplements logged
  recently that are not favorites yet. Picking a recent one saves it as a favorite first, the same copy
  the Library's star makes.
  Nothing is offered or added that matches the same entries as an item already on the list (for
  example the same product saved once with breakfast and once with dinner), since both would count
  every entry of it.
- **Schedule.** One to six distinct times a day and at least one day of the week; a new item starts at
  08:00 every day. Removing an item from the list keeps the favorite and every entry.
- **Taken is read, not stored.** Each load counts today's entries of each item in the journal: an entry
  logged from the Library counts too, and deleting or undoing an entry un-marks its time. An entry's day
  is the local day of its own time zone, the rule the Journal groups by. Entries match an item by its
  product snapshot, or by category and component names when there is none; the meal is ignored.
  Each of today's entries, in time order, belongs to one time: the latest time at or before it (on
  time or late), unless the next time is at most an hour away and nearer (early); an entry before every
  time belongs to the first. It marks that time taken; an entry whose time is already marked is an extra
  and marks nothing, so a missed morning stays "Not logged" whatever is logged in the evening. The count
  reads "1 of 2 taken today" from the marked times, with "logged N today" added when there were extras.
  A time with no entry reads "Not logged" once it has passed and "Later today" before; the wording
  reports the journal and gives no advice.
  An entry whose record cannot be read is not counted as missing: the screen says how many of today's
  entries it could not read, since any of them may be an item on the list.
  The screen reads the journal again when it appears, when the app returns to the foreground, and, while
  it is open, after any reload of the app's screens (an add, edit or delete anywhere, in any window). A
  list out of view reads nothing until it appears again. An erase or a restore drops the Undo offer and
  everything the list read, whether it is open or not. While
  it is open, the times move on once a minute from what was already read, so a passed time shows without
  a journal read; only a new day reads the journal again, which clears yesterday's marks.
- **Stored** as JSON under `supplementStack.schedules` in the app's defaults domain, one schedule per
  favorite id. Not in `favorites.store`, whose SwiftData schema is unversioned. A schedule whose
  favorite is gone is dropped on the next load. A damaged entry is skipped, not fatal to the list.
- **Erase all data** removes the key. Favorites are erased with their own store. An open list reads
  everything again when an erase or a restore finishes, so nothing erased stays on screen.
- **Not in the journal export yet.** Export schema version 2 has no field for schedules, so a restore
  brings the favorites back without their times. Adding them needs a new export schema version.
- **No notifications.** Supplement reminders are separate ([custom reminders](custom-reminders.md)).
- Not yet: Supplement Facts search to add a product directly, and upper-limit notes from the reference
  intakes table.
- Code: `NutritionUI/SupplementStack.swift` (schedule, today's times, stored schedules),
  `SupplementStackViewModel.swift`, `SupplementStackView.swift`. Tests: `SupplementStackTests`.
