# Insights

Reached from the **Trends** tab. It reads the Diary and nothing else, and makes no medical claim.

- **Seven days.** One bar per local day for the last seven days: how many entries each holds, "N of 7 days
  logged", the entry count and the days with no entries. A day with no entries is shown empty, not as zero
  intake. Each entry is filed on the day it has in the zone it was logged in, as the Diary files it.
- **Last 30 days.** The per-day average of energy, protein, carbohydrate and fat over the 30 local days
  ending today, counting only days whose total is known, with how many days that was. Absent when no day in
  the window has a known total for any of them.
- **When the Diary cannot be read** it says so instead of showing an empty week, and entries the Diary
  could not read are counted in a notice and not included.

Code: `InsightsWeek`, `InsightsAverages`, `InsightsView` and `InsightsHost` (in `TrendsView.swift`).
