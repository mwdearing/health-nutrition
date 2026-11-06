# Changelog

Recent changes to the Health Nutrition iOS app. The newest entry is first. This file lists what changed in the app and its contracts.

## Unreleased

- **#1330**: opening Privacy, Licenses or Daily goals from Settings no longer deletes the export file or clears the restore result; only leaving Settings does. Closes #1290.
- **#1308**: CI runs four Python test suites that no workflow ran before. The medication add, dose and edit fields have labels. Closes #1301.
- **#1307**: label scan no longer reads Polyunsaturated, Monounsaturated or Unsaturated Fat, or Soluble or Insoluble Fiber, as the total row. "Total Carbohydrates", "Carbohydrates" and "Total Sugar" are recognised. An extra row cannot overwrite a nutrient the person already answered. Closes #1283.
- **#1306**: the privacy manifest check scans each embedded bundle (app, widget extension, Watch app, Watch widget extension) against its own `PrivacyInfo.xcprivacy`, and an escaped backslash no longer hides the rest of a line. Closes #1302.
- **#1304**: a weight-gain plan starts from the floored maintenance figure (1500 kcal male, 1200 otherwise) and adds its surplus, so a gain target is always above maintain for the same answers. Closes #1298.
- **#1305**: withdrawing a shared product contribution that is already withdrawn returns `revision_conflict` with `current_state` "withdrawn" and writes nothing; only an exact replay returns the original receipt. Closes #1281.
- **#1329**: Insights no longer counts a water-only or supplement-only day as logged. The Medications tile shows the last-dose line. Recipe rows say "1 ingredient", and a failed recipe read clears stale rows. Closes #1295, #1296, #1314.
- **#1325**: the label review serving size can be corrected whether or not the parser flagged it. Review buttons are spoken with their on-screen titles first. Closes #1312.
- **#1318**: the supplement Shortcut picks the nearest open time within today without wrapping past midnight, so a late-evening time is tonight's. Closes #1300.
- **#1333**: Today follows midnight, time-zone and clock changes while open and reads Health again. Undo water closes on time. The first-day Apple Health row shows its status and opens the Health app once Health has answered. The startup failure screen has Try again. Closing an entry sheet always reloads the screens behind it. Closes #1327, #1328.
- **#1332**: automatic Apple Health delivery no longer reads the whole journal on every reload for people who never connected Apple Health. Closes #1326.
- **#1331**: the Watch app handles the Watch Connectivity background task, so a summary sent while the Watch app was closed is applied and the complications reload. Closes #1299.
- **#1323**: the product editor's button reads "Save and share product" when saving also shares, with a line saying what is sent. If sharing stopped being allowed, the confirmation says "Saved on this device only; sharing isn't available right now". Closes #1287.
- **#1321**: adds the version 8 export example and a test, run in CI, that keeps the Swift copies of the export contracts identical to `contracts/journal-export`. Closes #1303.
- **#1319**: a second tap on Quick add Log or on the medication dose Save during dismissal no longer writes a duplicate. Closes #1313.
- **#1317**: when Apple Health is connected but its water read fails, Today's water reads "at least" the known part and the goal bar notes the gap. Closes #1294.
- **#379**: vitamin D wording in the units contract. Vitamin D in IU is the one exception to the power-of-ten rule, at 0.025 mcg per IU. Sums asked in IU keep IU. The IU-unknown rule now covers vitamin A only.
- **#355**: vitamin D stated in IU counts as mcg wherever amounts are summed, in recipes, and when written to Apple Health. Vitamins A and E stay unknown in IU. Recipe snapshots keep their id unless the stored content differs.
- **#356**: macro split follow-ups. Shared follow helpers, a notice when a new energy goal is too small to share out, and Clear all keeps the split when it removed nothing.
- **#347**: Week view on vitamins and minerals. Each nutrient averages over its own logged days. Upper limits are checked day by day. Entries bucket by their own local date.
- **#345**: reference values are offered as goals. A row shows the RDA for the person's sex and age band, with a Use action. Goals fields follow the store unless the person has typed in them.
- **#350**: pregnancy and breastfeeding reference values for women aged 19 to 50. Phosphorus pregnancy upper limit is 3,500 mg.

## Open fix PRs (not merged)

From the security, bug and usability review of 2026-11-05. Each line moves under Unreleased when its PR merges, and is dropped if the PR closes unmerged.

- **#1324**: the custom product editor accepts the region's decimal comma and shows plain-sentence field errors. Closes #1288.
- **#1320**: USDA servings are stored in grams and shown in ounces only for display, rounded, with previews and saves using the exact grams. Source lines say "Food search" and "Custom product". Singular wording, clearer amount errors, and the Brand field stays while it is cleared. Closes #1285, #1289.
- **#1316**: the privacy statement says Health readings are not uploaded but totals can show on widgets and a paired Apple Watch. The in-app summary names USDA FoodData Central and the Health nutrition reads. Closes #1286.
- **#1315**: a day with only Apple Health intake no longer shows "Nothing logged today" on the widgets. Closes #1297.
- **#1311**: vitamins and minerals "today" and Week use the Diary's today, with entries in their own zone. Apple Health totals count toward the supplement list's upper-limit check. The source line lists the food, supplement and Apple Health parts. Closes #1291, #1292, #1293.
- **#1310**: an owner-reviewed shared product ranks ahead of unreviewed groups as the representative and in alternatives, whatever the support. Stored search entries are rebuilt to match. Closes #1282.
- **#1309**: an Apple Health or relay write for an entry deleted inside its 10-second Undo window is held, not settled, so Undo restores an entry that still gets written. Closes #1284.

## Versions

App version 0.1.30 (`ios/HealthNutrition/project.yml`).
