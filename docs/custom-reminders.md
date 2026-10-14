# Water and supplement reminders

Status: Current. Reviewed with [daily reminder](reminders.md) whenever the notification permission or erase flow changes.

Beside the one daily log reminder, a person can keep several reminders for water and for supplements.

- Each has a kind (water or supplement), a time of day and a switch. The settings rows show one of each kind (the controller allows up to 10).
- Off by default: a fresh install has none. The system permission prompt appears the first time a
  reminder is added or switched on and the app has not been asked; launch never asks.
- Local notifications only. No remote push, entitlement or background mode. Nothing is sent anywhere.
- Text names no health data: "Time for some water" / "Time for your supplements", and a line asking the
  person to open the app.
- Stored as JSON under `display.reminders.custom`; requests are named `custom-reminder-<id>`, separate
  from the daily reminder's identifier.
- Erase all data removes the list and cancels every request. Refused or withdrawn permission switches
  the reminders off and says so.
- Code: `CustomReminders.swift`, `CustomRemindersView.swift` (NutritionUI),
  `SystemCustomReminderScheduler.swift` (app). Tests: `CustomReminderControllerTests`.
- Shown inline in Settings under "Units and logging": one water and one supplement switch, each with a time while on.
