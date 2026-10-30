# Weight trend and planned goal date

The domain layer can turn logged weights into a trend and set it next to the pace a person chose in
goal setup. Both are plain numbers. Nothing here grades the result, picks a pace, or gives advice.

The code is `NutritionDomain/CalendarDay.swift`, `NutritionDomain/WeightTrend.swift` and
`NutritionDomain/PlanProjection.swift`. It is pure decimal arithmetic on whole days, with no clock,
calendar object or time zone.

## Days

`CalendarDay` is a Gregorian date with no time. The caller turns each sample's time into the person's
local day before it reaches the domain layer. Adding and counting days is integer arithmetic, so the
same samples give the same answer on every device.

## The trend

`WeightTrend.compute` takes the samples, the last day to include and an optional goal weight.

- **Window.** The last 28 days by default, ending on the given day. A caller may ask for 14 to 56
  days; other values are clamped into that range.
- **Same day.** Several samples on the same day are averaged into one value for that day. Samples
  outside the window are ignored.
- **Enough data.** The trend needs at least two days with samples, and the first and last of them must
  be at least 7 days apart. Otherwise the weekly change, trend weight and projected date are all empty,
  and the result still reports how many days it saw.
- **Line.** A least squares line through the daily values, with each day's position counted from the
  start of the window. The weekly change is the slope times 7; the trend weight is the line's value on
  the last day. Both are rounded to 2 decimal places, halves away from zero. A negative weekly change
  means the weight is going down.
- **Projected goal date.** Only when a goal is given, the line is not flat, and it moves toward the
  goal. The days to the goal are the distance from the unrounded trend weight to the goal divided by
  the unrounded daily slope, rounded to 6 decimal places and then up to a whole day. A nearly flat
  line can put that day thousands of years away; a day after 9999-12-31 is left empty.

## The planned goal date

`PlanProjection.goalDay` works from the current weight, the goal and the weekly pace: the distance
divided by the pace, times 7 days, rounded to 6 decimal places and then up to a whole day, the same as
the trend's projected date. There is no date for a pace that is not above zero, when the current weight
already equals the goal, or when the day would fall after 9999-12-31.

`PlanProjection.plannedWeeklyChangeKilograms` signs the pace by the aim: negative for losing, positive
for gaining, zero for maintaining or just tracking.

`PlanProjection.compare` puts the planned weekly change and planned goal date next to the trend's
weekly change and projected goal date. The planned date is counted from the trend's last day, and only
when the aim points at the goal (losing toward a lower goal, gaining toward a higher one).

## Weight plan

A weight plan is the aim a person chose in goal setup, with its goal weight and weekly pace. It holds:

- **Aim.** One of `lose`, `maintain`, `gain` or `just-track`. Just tracking carries no plan.
- **Goal weight.** Required when losing or gaining, within the goal weight range of `GoalEstimator`.
- **Weekly pace.** Required when losing or gaining, within the pace range of `GoalEstimator`.

Maintaining carries neither a goal nor a pace. Losing needs a goal below the current weight, and gaining
needs a goal above it. `WeightPlan.validate()` checks the plan alone, and `validate(currentKilograms:)`
also checks the goal's direction against the current weight. The checks run in a fixed order, so the same
plan always reports the same error.

The plan is stored in `goals.store`, beside the daily nutrient targets, through `WeightPlanStore`. One plan
is stored at most: writing a plan replaces the stored one, and removing a plan with none stored is not an
error. An invalid plan is refused before anything is written. A stored row that cannot be read is reported
as corrupt, never as "no plan".

Goal setup saves the plan when a person taps Save goals, after the targets and only once they are saved. A
losing or gaining aim stores the goal weight and pace the person chose; a maintain aim stores the aim alone;
just tracking does not change a stored plan. The plan is checked against the current weight before any
target is written, so a goal on the wrong side of it saves nothing.

**Erase all data** removes the weight plan together with the targets, in the same save. The plan is
not in the export: the export carries the journal and, from version 8, the daily targets, but never the plan.

## On Today

The "Activity and weight" card on Today shows the weight and up to four lines under it, in this order:

- **Trend weekly change.** From the weigh-ins of the last 28 days ending today. Example: `Trend: down 0.5 kg a week`. It reads `Trend: no change` when the change rounds to zero at two places.
- **Plan pace.** Shown only for a saved loss or gain plan. Example: `Plan: down 0.25 kg a week`.
- **Planned goal day.** Shown only for a saved loss or gain plan whose goal has not been reached. Example: `Plan reaches 80 kg on Dec 23, 2026`.
- **Trend goal day.** Shown when the trend projects a goal day. Example: `Trend reaches 80 kg on Aug 19, 2026`.

The planned day counts from today, starting from the trend weight, or, when there is no trend, from the
latest weigh-in if it falls within the same 28 days. An older weigh-in still shows as the weight, but
no planned day is shown. The card reads the saved plan each time it loads, so a plan saved in goal setup appears the
next time Today loads. Days are Gregorian dates in the device's time zone, also on a device set to another
calendar. Nothing on the card grades the figures.

## Units and wording

Every value is in kilograms, the same as goal setup. The screen converts to the person's chosen units
when it shows them; pounds are a display concern only.

The comparison is shown side by side as numbers. It carries no status, label or verdict, and the app
does not judge whether either number is good.
