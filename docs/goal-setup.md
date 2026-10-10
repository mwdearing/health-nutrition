# Goal setup: estimated daily targets

The Goals screen has a "Help me set my goals" row. It opens a short guided setup that turns a few
answers into daily targets. The person sees the numbers, can change any of them, and then saves the
ones they keep. Nothing is saved until they tap Save goals.

## What is asked

1. Aim: lose weight, maintain, gain, or just track (no targets).
2. About you: female, male or prefer not to say, and age in whole years.
3. Body: height and weight, in centimeters and kilograms or in feet, inches and pounds, following the
   unit system in settings. Pounds and inches are converted exactly.
4. Activity: how active the person is in a usual week.
5. Pace, for losing or gaining only: 0.25, 0.5, 0.75 or 1 kg a week (0.5, 1, 1.5 or 2 lb a week).
6. Results: energy, protein, carbohydrate, fat and fiber, each editable before saving.

Just tracking ends after the aim with a message and saves nothing.

## How the numbers are worked out

The calculator is `NutritionDomain/GoalEstimator.swift`. It is pure arithmetic in decimals:

- Resting energy uses Mifflin-St Jeor: `10 * kg + 6.25 * cm - 5 * age + s`, where `s` is +5 for male,
  -161 for female and -78 when the sex is not given.
- Daily energy is resting energy times the activity multiplier: 1.2 (little or no exercise), 1.375
  (light, 1 to 3 days a week), 1.55 (moderate, 3 to 5 days a week) or 1.725 (hard, 6 to 7 days a week).
- Losing or gaining adds or takes away the pace times 7700 kcal per kilogram, spread over 7 days. The
  daily change is capped at 1000 kcal.
- A loss never goes below 1500 kcal for a male or 1200 kcal for anyone else. When the cap or a floor
  changes the number, the results say so.
- Energy is rounded to the nearest 10 kcal. Carbohydrate is 50% of energy at 4 kcal a gram, protein 20%
  at 4 kcal a gram, and fat 30% at 9 kcal a gram, each rounded to the nearest 5 g. Fiber is 14 g per 1000
  kcal, rounded to the nearest 1 g.

The estimate is for adults: age 18 to 100, height 120 to 230 cm, weight 30 to 300 kg, and a pace of 0.1
to 1.0 kg a week. Outside those ranges the setup says what to check and computes nothing.

## Privacy

Age, sex, height and weight are used only to compute the numbers. They are held in memory while the
sheet is open, are never stored, logged or sent, and are cleared when the sheet closes. The first screen
says so: "Your answers stay on this phone and are not saved. Only the targets you choose are."

Only the targets a person saves are written, through the same goal store the Goals screen uses, in the
stored units (kcal for energy, grams for the rest). Saving replaces any target already set for those
nutrients; a blank result removes that target.

## Wording the results carry

"These are estimates, not medical advice. If you are pregnant, have a medical condition or take medicines
that affect weight or appetite, ask your doctor or dietitian."

## Code

- `NutritionDomain/GoalEstimator.swift`: the calculator and its error cases.
- `NutritionUI/GoalSetupViewModel.swift`: the steps, the answers, the estimate and the save.
- `NutritionUI/GoalSetupView.swift`: one screen per step, shown as a sheet from `GoalsView`.
- Tests: `NutritionDomainTests/GoalEstimatorTests.swift` and `NutritionUITests/GoalSetupViewModelTests.swift`.
