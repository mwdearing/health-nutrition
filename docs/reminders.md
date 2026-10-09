# Daily reminder

Status: Current. Reviewed whenever the notification permission flow or the erase flow changes.

The app can show one optional daily reminder: a notification on this phone at a time the person
chooses, asking them to log what they have eaten. It is off by default and nothing is sent anywhere.

## What it does

- **One reminder, at one time.** The default time is 20:00. A person can choose any time of day in
  Settings. Only one reminder exists at a time; changing its time replaces it.
- **Off by default.** A fresh install schedules nothing.
- **Asks for permission only when switched on.** The system notification prompt appears only when a
  person turns the reminder on and the app has not yet been asked. Launching the app, returning to it,
  and screenshot runs never show the prompt.
- **Counts provisional and quiet delivery as allowed.** Provisional and ephemeral authorization deliver
  quietly, so they are treated as allowed. A refused or withdrawn permission schedules nothing.
- **Text with no health data.** The title is "Log your meals" and the body is "Open Health Nutrition to
  add what you have eaten today."
- **Local only.** The reminder is a local notification. It does not use remote push, does not add an
  entitlement, a background mode or an Info.plist key, and does not change the app's delivery settings.
- **Settings row.** The switch and the time picker sit in Settings under "Units and logging". The
  footnote says: "A reminder on this phone at the time you choose. Nothing is sent anywhere."
- **Erase all data removes it.** The erase cancels the pending request and clears the stored switch and
  time. See [erase all data](erase-all-data.md).

## Where the code is

- `ios/NutritionCore/Sources/NutritionUI/ReminderPreferences.swift`: the time value (clamped to a 24-hour
  clock) and the stored settings protocol. The two keys are `display.reminder.on` and
  `display.reminder.time`, which holds "HH:mm".
- `ios/NutritionCore/Sources/NutritionUI/ReminderScheduling.swift`: the seam to the system, with the
  permission states and the single request identifier.
- `ios/NutritionCore/Sources/NutritionUI/ReminderController.swift`: the rules for switching on and off,
  changing the time, the launch sync and the refresh after an erase.
- `ios/NutritionCore/Sources/NutritionUI/ReminderEraser.swift`: the erase hook that cancels the request.
- `ios/HealthNutrition/Sources/SystemReminderScheduler.swift`: the only file that talks to the system
  notification centre. It is the only file in the app that imports the notifications framework.
- `ios/HealthNutrition/Sources/AppServices.swift` and `RootView.swift`: the controller is created once
  for the app's lifetime, synced at launch and each time the app becomes active.

## How to test

- The rules are covered by `ReminderControllerTests`, `ReminderPreferencesTests` and the erase case in
  `AppServicesEraseTests`, all run by the Swift test job in CI. They use a fake scheduler, so no
  notification is scheduled while the tests run.
- On a device, switch the reminder on once to see the prompt, then check the pending request in the
  system's notification settings for the app. Turning it off, or erasing all data, must remove it.
