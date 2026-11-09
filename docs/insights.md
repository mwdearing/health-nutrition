# Insights

Reached from the **Trends** tab. It reads the Diary, and Apple Health where it is connected, and makes no medical claim.

## The Trends tab

Trends opens on a Week, Month and 6 months picker (Week at first; the choice is not kept) above two cards and
its Vitamins and minerals and Insights rows. Both cards cover the chosen range of local days ending today (each card
says "Last 7 days", "Last 30 days" or "Last 6 months") and average over the days Insights counts for its averages
(a day with a food or drink entry, or with intake Apple Health states), using the same rule over the same days. The
Insights rows average 30 days, so their figures can differ from the cards. The days are read once, by the same
function Insights uses, so Health-only days are included, and Health is read for the chosen range. With nothing
counted, both cards say "Nothing logged this week" (or "this month", or "in 6 months") and show no figure or bar.

- **Calories, daily average.** The average as a large figure, and how far it is from the daily calorie goal, always
  as a positive figure: "150 under goal", "150 over goal" or "On goal". Below it, one bar per day for a week (today's bar is
  marked and its day letter bold), 30 daily bars for a month with a date under about one bar in seven, and 26
  weekly bars for 6 months, each the average of that week's counted days and labelled by the week's first day and a dashed line at the goal labelled with its value. When a counted day states only part of a figure, the figures read "at least", as Insights does. With no calorie goal (none
  set, or a goal of zero) there is no line and no difference. It is one VoiceOver element that reads the average, the
  difference and each day's figure; the chart height grows with the text size, up to a cap.
- **Macros, daily average.** One bar split into protein, carbohydrate and fat by their share of the calories the
  averaged grams make (4, 4 and 9 calories per gram), and a legend with the grams of each. The colours only fill the
  bar and the legend dots; the words and grams carry the meaning.

Code: `TrendsRange`, `TrendsSummary`, `TrendsCaloriesCard` and `TrendsMacrosCard` in `TrendsSummaryCards.swift`.

- **Last 7 days.** One bar per local day for the last seven days, drawn as a bar chart whose height grows with the text size: how many entries each holds, "N of 7 days
  logged", the entry count and the days with nothing logged. A day with nothing logged is shown empty, not as zero
  intake. Each entry is filed on the day it has in the zone it was logged in, as the Diary files it. A day
  Apple Health states a food or drink amount for also counts as logged, though it has no entry; water alone, a
  zero, a failed read and Health not connected do not (#1267). A day with only water or supplements is not logged
  either, the same rule as the Diary's week card and the 30-day averages; those entries still count in the entry
  count, which stays the Diary's.
- **Last 30 days.** The per-day average of energy, protein, carbohydrate and fat over the 30 local days
  ending today, with how many days that was. A fully known day counts as it is. A partly logged day counts with
  the sum of its known entries, so when any such day is included the line reads "at least" (a minimum, #510).
  A day with nothing known for a nutrient is left out of that nutrient's count and is never counted as 0.
  Where Apple Health is connected, each day's Health amounts are added to the Diary's as Today adds them: a
  completed query is a known amount (a known zero with no samples), a query that did not run leaves the day a
  minimum (or out of that nutrient's average when the journal states nothing for it), an amount in another unit
  than Health's is never converted or added, and a day only Health knows about counts (water alone does not) (#1268).
  Absent when no day in the window has a known amount for any of them.
- **When the Diary cannot be read** it says so instead of showing an empty week, and entries the Diary
  could not read are counted in a notice and not included.

Code: `InsightsWeek`, `InsightsAverages`, `InsightsView` and `InsightsHost` (in `TrendsView.swift`).
