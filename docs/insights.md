# Insights

Reached from the **Trends** tab. It reads the Diary, and Apple Health where it is connected, and makes no medical claim.

- **Last 7 days.** One bar per local day for the last seven days: how many entries each holds, "N of 7 days
  logged", the entry count and the days with nothing logged. A day with nothing logged is shown empty, not as zero
  intake. Each entry is filed on the day it has in the zone it was logged in, as the Diary files it. A day
  Apple Health states a food or drink amount for also counts as logged, though it has no entry; water alone, a
  zero, a failed read and Health not connected do not (#1267). The entry count stays the Diary's.
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
