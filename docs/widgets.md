# Widgets

The **Today** widget shows the day's calories (against the energy goal when there is one) and, in the larger
sizes, protein, carbohydrate, fat and water, on the Home Screen (small, medium) and the Lock Screen (circular,
rectangular, inline). With nothing logged it reads "Nothing logged today". Tapping it opens the app.

- **What it reads.** Only a small summary file the app writes (`Shared/WidgetSnapshot.swift`): the day's
  totals as numbers and whether any entry exists. No entry, product name, time or note is in it.
- **Where it lives.** In the App Group container shared by the app and the widget extension, named
  `group.<the app's bundle identifier>`, with file protection "complete until first user authentication".
  It is replaced whenever Today's figures change and when the app starts.
- **Lock Screen.** The figures are marked privacy sensitive, so the system redacts them while the device is
  locked, according to the person's Lock Screen widget settings.
- **Erase all data.** Removes the summary file with the stores and preferences. Today then reloads empty and
  the app writes an empty summary (no entries, no figures), so the widget shows "Nothing logged today".
- **Not readable yet.** After a restart and before the first unlock the file is protected; the widget then
  shows dashes rather than claiming nothing was logged.
- **Backups and accounts.** The App Group container is part of device backups like the rest of the app's
  files, and the summary is per device: signing out of an account does not change it.
- **Nothing is sent anywhere.** The widget has no network access and links no package.
- **Signing.** The extension's identifier is the app's plus `.widgets`; both carry the App Groups capability.
  The workflows set `APP_BUNDLE_ID`, never `PRODUCT_BUNDLE_IDENTIFIER`, so the extension and the group follow
  whichever identifier is signed.

Not built yet: a water button on the widget or Lock Screen (it needs the Log water intent split from the app's
services so it can run from the extension), and configuration options.
