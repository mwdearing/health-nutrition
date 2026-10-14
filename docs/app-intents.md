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
`WaterShortcut`), `AppServicesRegistry.swift`. Not built yet: a Lock Screen control and widgets, which need a
widget extension and an App Group; and "Log supplement taken", which follows the supplement stack.
