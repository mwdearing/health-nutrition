# Changelog

Recent changes to the Health Nutrition iOS app. The newest entry is first. This file lists what changed in the app and its contracts.

## Unreleased

- **#379**: vitamin D wording in the units contract. Vitamin D in IU is the one exception to the power-of-ten rule, at 0.025 mcg per IU. Sums asked in IU keep IU. The IU-unknown rule now covers vitamin A only.
- **#355**: vitamin D stated in IU counts as mcg wherever amounts are summed, in recipes, and when written to Apple Health. Vitamins A and E stay unknown in IU. Recipe snapshots keep their id unless the stored content differs.
- **#356**: macro split follow-ups. Shared follow helpers, a notice when a new energy goal is too small to share out, and Clear all keeps the split when it removed nothing.
- **#347**: Week view on vitamins and minerals. Each nutrient averages over its own logged days. Upper limits are checked day by day. Entries bucket by their own local date.
- **#345**: reference values are offered as goals. A row shows the RDA for the person's sex and age band, with a Use action. Goals fields follow the store unless the person has typed in them.
- **#350**: pregnancy and breastfeeding reference values for women aged 19 to 50. Phosphorus pregnancy upper limit is 3,500 mg.

## Versions

App version 0.1.30 (`ios/HealthNutrition/project.yml`).
