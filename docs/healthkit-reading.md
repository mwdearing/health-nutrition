# Reading from Apple Health

Status: current. The app reads three Health types for the activity card, and asks Health to read every nutrient type it writes (see below), only after the person asks.

| Type | Shown | Window |
|---|---|---|
| Steps (`stepCount`) | Today's activity card | Sum since local midnight |
| Active energy (`activeEnergyBurned`) | Today's activity card | Sum since local midnight |
| Weight (`bodyMass`) | Today's activity card, with the change since an earlier sample, labelled with the actual number of days | Latest sample, and the newest one at least 30 days before it |

The read request also covers the nutrient types the app writes (`OutsideIntakeTotals.readQuantityTypeIdentifiers`, defined beside the write plan), so the outside-intake totals can be read back. The table is the card's three types only.

- **When:** the card on Today shows a "Show steps, activity and weight" button until the read request has been shown once on this device (`healthKitReader.askedForReadAccess` in user defaults). Nothing is read before that.
- **What Health says:** HealthKit never reports whether read access was granted. A refused type reads as no data, so an empty card names both reasons and points to the Health app's Sharing screen.
- **Erase all data** clears the flag, so the card returns to its button.
- **Units:** weight follows the app's unit system (pounds for US, kilograms for metric); values are converted only for display.
- **Where it goes:** nothing read from Health leaves the phone or is stored by the app; the card reads again on every foreground.
- **Code:** `ios/HealthNutrition/Sources/HealthKitReader.swift` (the only reader), `ios/NutritionCore/Sources/NutritionUI/BodyActivity.swift` (card and view model, no HealthKit import).
- **Needs a device:** the permission sheet, real sums and weight samples.
