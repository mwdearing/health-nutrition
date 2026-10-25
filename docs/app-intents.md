# App Intents

**Log water** is available to Siri, Spotlight and the Shortcuts app ("Log water in <app name>").

- It opens the app and adds one water entry of the person's usual quick amount to today's diary, through
  the same path as the Today button, so it is queued for Apple Health like any other entry and can be
  undone for ten seconds from Today.
- It runs in the app's own process and uses the app's own store: there is one writer. If the app's stores
  could not be opened, or the intent runs before the app has started, it says "Open the app once, then try
  again" and writes nothing.
- Nothing is sent anywhere because of it; it is local like the rest of the journal.

Code: `HealthNutrition/Sources/LogWaterIntent.swift` (the intent and shortcut, with the testable
`WaterShortcut`), `AppServicesRegistry.swift`. Not built yet: a Lock Screen control. Today widgets are described in widgets.md.

**Log supplement taken** records one Taken for a supplement on your supplement list ("Log <supplement> in <app
name>", "I took <supplement> in <app name>", or the action in Shortcuts, which offers the items on your list).

- It opens the app and calls the same function the list's own per-time Taken button calls, so the entry, the
  recorded time, the undo window and the Apple Health queueing are exactly those of a tap on the list. With a
  time still open today it is the open time closest to when the shortcut runs (at 9 PM with 8 AM and 8 PM open
  that is 8 PM; at 11 AM it is 8 AM; a tie goes to the earlier time; distance is the difference in clock time within one day with no wrap
  past midnight, so at 00:10 with 12:00 and 23:50 open it is 12:00; a single open time is used however far
  away it is); with none open it is one Taken that marks
  no time, like the list's own Taken.
- It says "Logged <supplement>", or the list's own reason when the item cannot be logged ("This item has no
  amounts to log.", "This item is no longer on your supplements."), "Add a supplement to your list first." for
  an empty list, and "Open the app once, then try again." when the app's stores are unavailable.

Code: `HealthNutrition/Sources/LogSupplementIntent.swift` (`SupplementShortcut` holds the tested logic).

Both shortcuts:
- write nothing while Erase all data runs or a journal import (restore) is being applied, and Shortcuts' list of
  supplements stays empty during one (they answer "Could not log it. Try again." for supplements and "Could not save the water." for
  water);
- write a new entry each time they run: running one twice logs twice, and the Today and list Undo applies to
  the last one;
- look the list up from the store each time they run, so the picker in Shortcuts is current; that read can also
  tidy the list's saved times the way opening the list does.

**Log supplement taken and your supplement names.** The action needs the device unlocked and local device
authentication to run (the action sets `requiresLocalDeviceAuthentication`), and it speaks "Logged
<supplement>" only then. No list of your supplement names is offered while the device is locked: the picker in
Shortcuts and Siri's prompts get an empty list until you unlock (protected data is available only then). A
shortcut you already saved holds the item's id rather than a list, so it still resolves while locked, shown
with the stand-in title "Supplement" rather than the name, and then reaches the unlock requirement. The same
stand-in is used when the saved item is no longer on your list, so the action can say "This item is no longer
on your supplements."; asking Siri for a supplement by spoken name while locked does not resolve until you
unlock. Nothing leaves the device. Log water keeps its existing unlock behaviour and only gains the erase and
restore guard above.

After either shortcut writes an entry the app reloads Today, the Diary and the Library and runs a Health
delivery pass, as after an add in the app. The undo offer a supplement write creates lasts ten seconds, then
expires even if the list is not open; deleting the entry from Today or the Diary works at any time.

Device check for the first signed build: with the device locked, ask Siri to log a supplement when your list has
two items, and note what it says before it asks to unlock; open the Shortcuts picker on the locked device and
note that it lists nothing until you unlock; run a saved "Log supplement taken" shortcut while locked and
note that it asks you to unlock and then logs; and look for the items in Spotlight while locked.
