# Widgets

The **Today** widget shows the day's calories as Today does: "Calories remaining" in large type (when there is a
goal) with Food (fork and knife) and Burned (flame) under it, and, in the medium size, protein, carbohydrate, fat and
water beside it, on the Home Screen (small, medium) and the Lock Screen (circular, rectangular, inline). Remaining is
hidden without a goal, Burned without a burned value, and over goal it is a plain negative number. On a day where
some entries have no calories, Food reads "N+" (VoiceOver "at least N calories") and, while there is something left,
Remaining reads "Up to N" ("up to N calories remaining"); the medium widget adds its note line, and a small gauge
holds Food instead of the unmarked Remaining. Burned never has a marker. The circular
widget's ring is the share of the goal eaten. With nothing logged it reads "Nothing logged today". Tapping it opens
the app.

- **What it reads.** Only a small summary file the app writes (`Shared/WidgetSnapshot.swift`): the day's
  totals as numbers, the calorie goal, calories left (goal less food plus counted burned) and burned, which figures
  are only partly known, and whether any entry exists. The calories-left model is read once from Today, never
  computed again for the widget; an unknown figure is absent, never zero. No entry, product name, time or note is
  in it.
- **Where it lives.** In the App Group container shared by the app and the widget extension, named
  `group.<the app's bundle identifier>`, with file protection "complete until first user authentication".
  It is rewritten each time Today's figures are read successfully (see "When the summary is written").
- **Lock Screen.** The figures are marked privacy sensitive, which asks the system to redact them while the
  device is locked, according to the person's Lock Screen widget settings. PRIVACY.md does not promise this until
  the device check below has confirmed it; the sentence is added in a follow-up then.
- **Erase all data.** Clears the summary, and runs first among the erasers: it is replaced by an empty one (no entries, no figures) at once, so the
  widget shows "Nothing logged today"; if that write fails the whole folder is removed instead, and the widgets are
  refreshed either way. If the file cannot be removed either, it is emptied in place; the widget cannot decode an
  empty file and shows dashes. If even that cannot be done the erase reports failure to the person and the file
  stays until a later erase or write succeeds. A write that was already pending from before the erase is dropped by an erase counter
  (not the clock); Today then reloads and writes the real empty day.
- **Not readable yet.** After a restart and before the first unlock the file is protected; the widget then
  shows dashes rather than claiming nothing was logged.
- **How it is written.** The summary lives in its own folder inside the App Group container, and that folder is
  left out of device backups, so everything in it (a temporary included) is excluded from the moment it exists.
  A new summary is written to a fixed temporary name in the folder and moved over the file. If the folder cannot
  be left out of backups nothing is written and the folder is removed. A temporary left by a crash is removed at
  launch and by erase. The folder is created with the same file protection as the file, and the files in it are
  flagged as excluded too, so each reads back as excluded.
- **When the summary is written.** The app writes it each time Today has read the journal successfully, and
  stamps it with that moment (`TodayViewModel.lastLoadedAt`). Before the first successful load, after a failed
  reload, or when something merely notifies without reading, nothing is written, so a failed read never replaces
  valid totals and retained totals never look fresh. Figures too large to be a daily total (above one billion)
  show as dashes.
- **A new day.** A summary written on an earlier day is not shown as today's: with the app closed after
  midnight the widget shows dashes (the same state as unreadable) until the app writes today's summary. The
  widget asks to be refreshed shortly after local midnight for this.
- **Backups and accounts.** The summary file is excluded from device backups (it is rewritten at every load),
  and it is per device: signing out of an account does not change it.
- **Nothing is sent anywhere.** The widget has no network access and links no package.
- **Signing.** The extension's identifier is the app's plus `.widgets`; both carry the App Groups capability.
  The workflows set `APP_BUNDLE_ID`, never `PRODUCT_BUNDLE_IDENTIFIER`, so the extension and the group follow
  whichever identifier is signed. The App ID `<bundle>.widgets`, the group `group.<bundle>` and the App Groups
  capability on the app's App ID must exist in the developer account before a signed build; the first signed run
  creates the extension's profile through automatic signing, and its log is the check that it worked.
- **Privacy manifest.** The extension has its own: it declares nothing, because nothing leaves the device, which
  matches the app's manifest declaring nothing for these totals.

Device check for the first signed build: with the device locked, confirm the Lock Screen widget hides the
calorie figure and the gauge value (not only the Home Screen figures); the Lock Screen sentence is added
to PRIVACY.md in a follow-up only once that check confirms it; after Erase all data confirm the widget
reads "Nothing logged today"; after Erase all data also confirm the Lock Screen widget and the widget gallery preview read "Nothing logged today"
(WidgetKit keeps its own snapshot cache, which the system manages); and after midnight with the app closed confirm it shows dashes, not yesterday's
figures; and confirm the summary file is excluded from a device backup (its resource value
`isExcludedFromBackup` reads back true).

## Sending the summary to a paired Watch (phone side)

The phone sends a paired Apple Watch the same summary the widgets read, in an envelope
`{ schemaVersion, eraseGeneration, snapshot }` (`Shared/WatchSnapshotEnvelope.swift`). `snapshot` is the
`WidgetSnapshot` and nothing else: no entry names, meal times, supplements or account data. The channel is
WatchConnectivity's application context (latest value wins, device to device, no server). The sender
(`WatchSnapshotSender`) runs right after the summary is written, with the publisher's gates, and only when the
session is active, a Watch is paired and the Watch app is installed; otherwise the latest envelope is held and sent
on activation. The erase generation is kept across launches (two numbers in the app's defaults: the generation and
the newest generation the Watch has been handed), so it only ever goes up and an erase that was not delivered before the
app was closed is sent first at the next launch. A summary from a load that began before the latest erase is dropped
by the sender under the same lock the erase takes, so it can never replace the erase. Sends are serialized. A decoder tolerates unknown
fields; an unknown `schemaVersion`, a malformed payload or one over 4 KB decodes to "invalid" and is shown as dashes.
The real session sits behind `WatchSnapshotTransport` so everything above it is unit-tested with a fake, because
WatchConnectivity does not exist on the platform the package tests build on.

## The Watch app and Watch widgets

`HealthNutritionWatch` (watchOS 11, embedded in the phone app; identifier `<bundle>.watchkitapp`) receives the
envelope, applies it with `WatchSnapshotReceiver` and shows today's figures. It has no feature of its own and logs
nothing. It keeps the summary in its own App Group container (`group.<bundle>`, the same name as the phone's; each
device has its own container) using the same store, so the Watch widgets read it the way the phone's do.
`HealthNutritionWatchWidgets` (`<bundle>.watchkitapp.widgets`, embedded in the Watch app) offers circular,
rectangular, corner and inline complications and a Smart Stack card whose relevance rises around the usual meal
times; its timeline carries an entry at the next midnight that shows dashes.

The receiver ignores an envelope below the highest erase generation it has applied (kept across launches), stores an
empty day for the erase, and removes the stored summary for an unknown schema version, a malformed or an oversized
payload so the widgets show dashes. Delivery is background and budgeted by the system: the complication updates after
the phone app has run and the system has delivered, and the phone widget has the same limit.

Device check on a paired Apple Watch (signed build): the complication shows today's totals after the phone app opens
once; locked Watch (confirm which figures show, then add the sentence to PRIVACY.md only if confirmed); after Erase all
data on the phone the Watch reads "Nothing logged today", and with the Watch off during the erase it clears on
reconnect; airplane mode during a log, then back online, the figures catch up; after midnight with the phone app
closed it shows dashes; unpair and re-pair leaves no stale data; a Watch app one schema version behind the phone
shows dashes and does not crash.

Not built yet: a water button on the widget or Lock Screen (it needs the Log water intent split from the app's
services so it can run from the extension), and configuration options.
