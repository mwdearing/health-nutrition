# Widgets

The **Today** widget shows the day's calories (against the energy goal when there is one) and, in the larger
sizes, protein, carbohydrate, fat and water, on the Home Screen (small, medium) and the Lock Screen (circular,
rectangular, inline). With nothing logged it reads "Nothing logged today". Tapping it opens the app.

- **What it reads.** Only a small summary file the app writes (`Shared/WidgetSnapshot.swift`): the day's
  totals as numbers and whether any entry exists. No entry, product name, time or note is in it.
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

Not built yet: a water button on the widget or Lock Screen (it needs the Log water intent split from the app's
services so it can run from the extension), and configuration options.
