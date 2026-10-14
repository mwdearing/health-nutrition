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

Just tracking ends after the aim and saves nothing. When any target is already stored, the result says
"Your current targets are unchanged. You can change or remove them on the Goals screen." and the targets
stay as they are. When none is stored, it says "Nothing was saved. Your day will show totals without targets."

## How the numbers are worked out

The calculator is `NutritionDomain/GoalEstimator.swift`. It is pure arithmetic in decimals:

- Resting energy uses Mifflin-St Jeor: `10 * kg + 6.25 * cm - 5 * age + s`, where `s` is +5 for male,
  -161 for female and -78 when the sex is not given.
- Daily energy is resting energy times the activity multiplier: 1.2 (little or no exercise), 1.375
  (light, 1 to 3 days a week), 1.55 (moderate, 3 to 5 days a week) or 1.725 (hard, 6 to 7 days a week).
- Losing or gaining adds or takes away the pace times 7700 kcal per kilogram, spread over 7 days. The
  daily change is capped at 1000 kcal.
- A maintenance estimate or loss never goes below 1500 kcal for a male or 1200 kcal for anyone else.
  When the cap or a floor changes the number, the results say so. These are product guardrails for
  estimated targets, not individualized medical advice.
- Energy is rounded to the nearest 10 kcal. Carbohydrate is 50% of energy at 4 kcal a gram, protein 20%
  at 4 kcal a gram, and fat 30% at 9 kcal a gram, each rounded to the nearest 5 g. Fiber is 14 g per 1000
  kcal, rounded to the nearest 1 g.

The estimate is for adults: age 18 to 100, height 120 to 230 cm, weight 30 to 300 kg, and a pace of 0.1
to 1.0 kg a week. Outside those ranges the setup says what to check and computes nothing. With US customary
units the same limits are read as 4 ft 0 in to 7 ft 6 in, 67 to 661 lb and 0.3 to 2.2 lb a week. The least
value rounds up and the most rounds down, so every number the sentence names is inside the limits.

## Privacy

Age, sex, height and weight are used only to compute the numbers. They are held in memory while the
sheet is open, are never stored, logged or sent, and are cleared when the sheet closes. The first screen
says so: "Your answers stay on this phone and are not saved. Only the targets you choose are."

Only the targets a person saves are written, through the same goal store the Goals screen uses, in the
stored units (kcal for energy, grams for the rest). Saving replaces any target already set for those
nutrients; a blank result removes that target.

Saving is all or nothing. Before anything is written, each of the five nutrients' stored goals is read.
If a write or removal then fails, the goals already changed are put back exactly as they were read (a goal
that did not exist is removed again), the Goals screen keeps its own values, and the results stay on screen
with "Could not save your goals. Try again." A result that is blank, zero or not a number is not written:
each such field is marked "Enter a number greater than zero.", the summary reads "Enter a number above zero.",
and the fields keep what the person typed.

## Wording the results carry

"These are estimates, not medical advice. If you are pregnant, have a medical condition or take medicines
that affect weight or appetite, ask your doctor or dietitian."

## Reference values as goals

Once a group is picked on the vitamins and minerals screen ("Men 31 to 50", see [vitamins-and-
minerals.md](vitamins-and-minerals.md)), each vitamin and mineral row on the Goals screen that has no goal
shows that group's published value under it, "RDA 8 mg for Men 31 to 50" or "AI 120 mcg for Men 31 to 50",
with a **Use** button. Use writes it as an ordinary goal in the reference's own amount and unit, and sets the
row's field to it so leaving the field keeps the goal. It is a one-time copy: the goal is then the person's to
change, picking another group never rewrites it, and nothing new is stored. A row that already has a goal, a
row the reference table does not cover (chloride, sodium, the macronutrients, water), vitamins A, D and E
(kept off the Goals screen's fixed list because a label may state them in IU, vitamin E on older labels, which
a goal in mcg or mg cannot be compared with), a row where a number is being typed, and every row while no
group is picked show nothing. The value is worded and rounded as the vitamins and minerals screen states it,
and Use commits the row like a typed target, so an error the row showed is cleared.
`NutritionUI/GoalsViewModel+ReferenceGoals.swift`; tests in `NutritionUITests/ReferenceGoalsTests.swift`.

## Macros by percent

The Goals screen also has a "Macros by percent" section. A person types protein, carbohydrate and fat
as percentages of their energy goal; the three must each be above zero and total exactly 100. The
section shows the grams that comes to (4 kcal per gram for protein and carbohydrate, 9 for fat,
rounded to whole grams) and, on "Set gram goals from percentages", writes them as the ordinary gram
goals for those three nutrients. All three are written or none is.

Once all three gram goals are written, the split itself is stored as a display preference
(`display.goals.macroSplit`, for example `30,40,30`). The gram goals follow it exactly while the three
stored macro goals are its output for the energy goal; that is decided from the goals each time rather
than kept as a flag. While they follow, changing the energy goal on the Goals screen moves protein,
carbohydrate and fat to the split's share of the new energy goal, written all three or none, and the
section says the gram goals follow at those percentages. 30/40/30 of 2,000 kcal is 150/200/67 g;
changing energy to 2,500 kcal makes it 188/250/83 g.

So a gram goal changed by hand or by the setup estimate stops following (typing exactly the split's
grams back in resumes it), and so do removing the energy goal, an energy goal too small to share out
(the screen says so: "Your energy goal is saved, but it is too small to share out by your percentages, so
protein, carbohydrate and fat were left as they are and no longer follow it."), and goals changed behind
the screen; none of those rescales anything. Clearing all goals and erase forget the split, a clear that is
refused partway included, so it cannot resume when matching goals are typed again; a clear refused before
it removed anything changed nothing and keeps it. If a gram write is refused after the energy goal saved, the earlier gram goals are put back
and the screen says the macros could not follow, or, when putting them back fails too, that the three
may be a mix of old and new, with the fields refilled from what is stored. A percentage apply that saved
a changed energy goal before a gram write failed keeps that energy goal and says so ("Your energy goal is
saved, but protein, carbohydrate and fat could not be set from the percentages."). A failed apply or
setup save leaves the earlier split stored, and whether the goals still follow it is again decided from
the goals. The share shown back is still
worked out from the stored gram goals and the stored energy goal. The energy used is what the energy row shows: an edit typed there and not yet saved is used for the preview and saved before the gram goals. Without an energy goal the section only says to set one first. The app
offers no split of its own.

## Code

- `NutritionDomain/GoalEstimator.swift`: the calculator and its error cases.
- `NutritionUI/GoalSetupViewModel.swift`: the steps, the answers, the estimate and the save.
- `NutritionUI/GoalSetupView.swift`: one screen per step, shown as a sheet from `GoalsView`.
- Tests: `NutritionDomainTests/GoalEstimatorTests.swift` and `NutritionUITests/GoalSetupViewModelTests.swift`.
- `NutritionDomain/MacroSplit.swift`, `NutritionUI/GoalsViewModel+MacroSplit.swift` and
  `NutritionUI/MacroSplitSection.swift`: the percent split. Tests: `NutritionDomainTests/MacroSplitTests.swift`
  and `NutritionUITests/MacroSplitGoalsTests.swift`.
