# Vitamins and minerals: today against reference values

Today has a **Vitamins and minerals** card below the day's entries. It opens a screen that lists the 25 vitamins and
minerals the reference table covers (`docs/reference-intakes.md`) with what today's entries state for each (or, on
**Week**, the daily average over the last 7 days), and, once a person picks a group, how that compares with the
published adult values for it. The same screen is the Nutrients view on the Trends tab. The screen states comparisons only: it
gives no advice and no score.

## Day and week

A **Day / Week** switch sits at the top. **Day** is today, as described below. **Week** shows, for each
nutrient, the daily average over the last seven local days, today included: the amounts are summed exactly
as for a day and divided by the number of those days with at least one food or supplement entry (a water
entry does not count), so a day nothing was logged on does not pull every average down. Today counts as a
logged day once something is logged, so early in the day the averages read lower than they will end up. A
line says what the figures are ("Average per day over the 3 days you logged in the last 7.", or "Nothing
was logged in the last 7 days."), and VoiceOver reads each figure as a daily average. The "Not known"
heading reads "Not known this week", and without a group the amounts are under "Last 7 days".
"Unknown for 2 entries" still counts entries. A logged day whose entries do not state a nutrient still counts in that
nutrient's average, so the average is a floor there too: the row reads "At least" and "Below the RDA so far" rather
than as a complete figure.

Each average is compared with the RDA or AI, so "Below the RDA" on the week means the daily average is
below it. An upper limit is a daily limit, so it is checked day by day rather than against the average: a
week is "Above the upper limit" when any logged day was certainly above it, and the row says on how many
("Above the upper limit on 1 of 3 logged days."). Each entry's day is read in its own time zone, as on
Today, and entries dated after today are left out.

## Comparing with a group

**Compare with** offers the eight published adult rows ("Women 19 to 30" to "Men 71 and over") and **Nothing**. Until a
group is picked the screen shows amounts alone, because the sources publish no row for someone who has not said which one
is theirs. The choice is a display preference on this phone: `UserDefaultsDisplayPreferences` stores it under
`display.reference.group` as `<sex>.<age band>` (for example `female.years31To50`), a value that does not read back as one
published row is no group, and **Erase all data** removes it with the other display preferences.

The footer says what the values are: the published adult RDA or AI and upper limit, from the NIH Office of Dietary
Supplements, describing populations rather than the person, and not covering pregnancy, breastfeeding or anyone under 19.

## How the day is added up

Each of today's entries is summed on its own with `DailyTotalsBuilder`, so it contributes exactly what Today counts for it,
and supplements are summed apart from food. The day is each entry's own local day, as on Today. An entry whose stored time
zone is not a valid one cannot be placed on a day: it is left out, and the screen says so ("1 entry has a time zone the
app can't read and is left out, so these figures may be low.").

- An entry that states an amount adds it, converted into the nutrient's unit. An entry typed by hand is read component
  by component, so a component that states the nutrient keeps its amount even when another component does not; the entry
  then also counts as unknown.
- A food or drink that could state the nutrient but does not, or states it in a unit that cannot be added (vitamins A, D
  and E in IU), is counted as **unknown for that entry**. It adds nothing, so the figure becomes a floor ("At least 120
  mg") rather than letting one unlabelled food hide what the others do state.
- A water entry, and a supplement that does not declare the nutrient, say nothing about it and count nowhere.

## What each row says

| Status | When | Section |
|---|---|---|
| Above the upper limit | The part of the day the limit counts is above it | Above an upper limit |
| Below the RDA (or AI) | Every entry that could state it did, and the day is below | Below the reference |
| Below the RDA so far | What is known is below, and some entries do not state it | Below the reference |
| Reached the RDA | The known amounts alone reach it | Reached the reference |
| Unknown / Nothing logged | No entry states an amount / no entry could | Not known today (Week: Not known this week) |

"Above the upper limit" is only shown when the day certainly holds more than the limit counts, never as a guess. The rule
is one public function, `NutrientGaps.exceededLimit(intake:total:supplementTotal:)`, with its row wording in
`NutrientGaps.limitNote(_:)`, so another screen that warns about a limit says exactly the same:

| Limit (`UpperLimitScope`) | What is compared | Line under the row |
|---|---|---|
| Most nutrients (`allSources`) | Everything known, food and supplements | none |
| Magnesium (`supplementsAndMedicines`) | The supplement amount; medicines are not logged | "...supplements and medicines only, not food or water. Supplements are checked." |
| Niacin, vitamin E (`supplementsAndFortifiedFoods`) | The supplement amount; fortified foods cannot be told from other food | "...supplements and fortified foods, not food itself. Only supplements are checked." |
| Folate (`folicAcid`) | Not checked: the journal cannot tell folic acid from DFE amounts or methylfolate | "...folic acid only. The app can't tell it from other folate, so it isn't checked." |
| Vitamin A (`preformedVitaminA`) | Not checked: the journal cannot tell retinol from beta carotene | "...preformed vitamin A only. The app can't tell it from beta carotene, so it isn't checked." |

Food magnesium above 350 mg is therefore never shown as over a limit, and the folate limit reads "upper limit 1000 mcg
of folic acid" because it is not in DFE.

Each row also says where the amount came from ("Food 60 mg, supplements 500 mg", or "All from supplements"), how many
entries do not state it, and the reference figures ("RDA 90 mg, upper limit 2000 mg", or "AI 120 mcg, no upper limit
set"). The bar shows food and supplements side by side against the reference; past it, the bar is full and a mark shows
where the reference sits. The row is read by VoiceOver as one sentence.

Figures are rounded for reading only: one decimal place, two below 1, and "< 0.01" for an amount too small to show, so a
real amount is never shown as zero.

## Not yet

Past single days and longer spans are later work. IU conversion for vitamins A, D and E is not done: the factor depends on the form.
