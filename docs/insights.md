# Insights

Reached from the **Trends** tab. It reads the Diary and nothing else, and makes no medical claim.

- **Last 7 days.** One bar per local day for the last seven days: how many entries each holds, "N of 7 days
  logged", the entry count and the days with no entries. A day with no entries is shown empty, not as zero
  intake. Each entry is filed on the day it has in the zone it was logged in, as the Diary files it.
- **Last 30 days.** The per-day average of energy, protein, carbohydrate and fat over the 30 local days
  ending today, with how many days that was. A fully known day counts as it is. A partly logged day counts with
  the sum of its known entries, so when any such day is included the line reads "at least" (a minimum, #510).
  A day with nothing known for a nutrient is left out of that nutrient's count and is never counted as 0.
  Absent when no day in the window has a known amount for any of them.
- **When the Diary cannot be read** it says so instead of showing an empty week, and entries the Diary
  could not read are counted in a notice and not included.

Code: `InsightsWeek`, `InsightsAverages`, `InsightsView` and `InsightsHost` (in `TrendsView.swift`).
