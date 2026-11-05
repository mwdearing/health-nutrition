# App Store Connect metadata

Status: Draft for the first App Store release. Every claim below is checked against `README.md`, `PRIVACY.md`,
`docs/` and `ios/HealthNutrition/project.yml` at the commit this file was merged. Re-check it when a feature
changes. Nothing here claims a score, advice or a medical effect, and the verb for adding an entry is "Log".

## Character counts

| Field | Characters | Limit |
| --- | --- | --- |
| Name | 26 | 30 |
| Subtitle | 28 | 30 |
| Promotional text | 167 | 170 |
| Keywords | 95 | 100 |
| Description | 2267 | 4000 |
| What's New | 325 | 4000 |
| Review notes | 1936 | 4000 |

Counts are Unicode characters as Python's `len` reports them. The keyword field counts the commas.

## Name and subtitle

- Name: `Health Nutrition: Food Log`
- Subtitle: `Log food, water, supplements`

The app's display name on the Home Screen is `HealthNutrition` (`CFBundleDisplayName`). Apple requires an
app name that no one else holds; if `Health Nutrition: Food Log` is taken, use `Health Nutrition Journal` (24) or `Health Nutrition Log` (21).

## Promotional text

Log food, drinks, water and supplements in one private journal. Scan a barcode or label, see your day against goals you set, and send it to Apple Health if you choose.

## Keywords

`calorie,macro,nutrition,food diary,supplement,vitamin,mineral,hydration,barcode,protein,tracker`

Words already in the name and subtitle (log, food, water, supplements) are not repeated, because Apple indexes them.

## Description

Health Nutrition is a private food, drink and supplement journal. Log what you have, see your day against goals you set, and keep it all on your phone.

LOG IT YOUR WAY
- Scan a package barcode, scan a Nutrition Facts or Supplement Facts label, search foods by name, or type it in.
- Log water with one tap on Today, or type another amount.
- Keep favorites, recent items and saved meals, and log them again in a tap.
- Build your own recipes and log a serving.
- Create your own products with the nutrition facts you enter.

SEE YOUR DAY
- Today shows calories, protein, carbohydrate and fat, plus a bar for every other nutrient you track, against goals you set. Set the goals yourself, or answer a few questions to start from an estimate and change it any time.
- The Diary lists every day by meal. Open any entry to fix the amount, time or day.
- Trends shows the last 7 days and 30-day averages from your own Diary. A day you did not log is shown as empty, not as zero.
- See vitamins and minerals for the day beside published reference values.
- Use US or metric units.

SUPPLEMENTS AND WATER
- Keep a list of your supplements and log them like any other entry.
- Set optional reminders to log water or supplements. They are off until you turn them on.

APPLE HEALTH, ONLY IF YOU CHOOSE
- Connect Apple Health in Settings and the nutrients and water you log are written to Health. Disconnect any time in the Health app.
- If you allow it, the app can also read your steps, active energy and weight to show on Today, and the nutrients other apps logged so your totals match.

MORE
- Today widgets for the Home Screen and Lock Screen, and an Apple Watch app.
- Log water, a saved meal or a supplement from Siri, Spotlight or Shortcuts.
- Export your journal to a file you choose, and restore it later.
- Erase all data in Settings clears the journal on this device.

PRIVATE BY DESIGN
- Your journal stays on this device. The app has no ads, no analytics and no tracking.
- Barcode and name lookups send only the barcode or the words you submit.
- An account is optional. Sign in with Apple or an emailed code only if you want to share product labels with the community catalog.

Health Nutrition is a journal. It does not give scores, advice or medical guidance.

## What's New

First release.
- Log food, drinks, water and supplements by barcode, label scan, name search or typing.
- Today, Diary, Library and Trends.
- Goals you set, with bars for calories, macros and other nutrients.
- Optional Apple Health connection, widgets, Apple Watch app and Siri Shortcuts.
- Export and restore your journal.

## URLs

| Field | Value | Note |
| --- | --- | --- |
| Support URL | https://github.com/mwdearing/health-nutrition/issues | The repository is public. The issue tracker needs a GitHub account to post. |
| Privacy Policy URL | https://github.com/mwdearing/health-nutrition/blob/main/PRIVACY.md | The policy in the repository. |
| Marketing URL (optional) | https://github.com/mwdearing/health-nutrition | The repository has no separate site. Leave this blank if you prefer. |

## Age rating

Answer the age-rating questionnaire as follows. Apple computes the final rating from the answers, so confirm the
result in App Store Connect, since the questionnaire's wording changes.

| Question area | Answer | Why |
| --- | --- | --- |
| Violence, sexual content, nudity, profanity, horror, mature themes | None | The app has none. |
| Alcohol, tobacco or drug references | None | The app does not feature them. A person can type any name for a food or drink, but the app supplies no such content. |
| Gambling, contests | None | None. |
| Medical or treatment information | None | The app is a journal. It gives no medical information, no advice and no treatment guidance. |
| Health or wellness topics | Yes, infrequent | It logs nutrition, water and supplements. It gives no scores or advice. |
| Unrestricted web access | No | The app only calls its fixed lookup services. It has no browser. |
| User-generated content or messaging | No | A person can share a product label's facts with the community catalog after owner review. There is no chat, posting or free-text social feature. |
| Parental controls, age assurance | No | None. |
| In-app purchases, ads | None | The app has neither. |

## Review notes

```text
Sign-in: none is needed. The app is fully usable signed out, and the reviewer does not need an account or a password. An account is optional and is used only to share product labels with the community catalog and to look up barcodes in that catalog. If you want to see it, Settings > Account offers Sign in with Apple, or an emailed one-time code (this may show an hCaptcha human check first). Delete account is in the same place.

First launch: a welcome screen appears once. Tap Get started. Nothing is requested at launch.

How to see the main flow: on Today, tap Add food, drink, or supplement, type a name and an amount, and save; tap a quick-add water button; open the Diary tab to see the entry. Search foods sends the words you submit to USDA FoodData Central and Open Food Facts.

Apple Health (HealthKit): off until the user taps Connect Apple Health in Settings. It is used only for nutrition logging: (1) it writes the nutrients and water of entries the user logs, and removes them again when the user edits or deletes an entry; (2) after the user connects, it reads the nutrient types it writes so Today's totals include nutrition other apps logged; (3) only if the user taps Show steps, activity and weight on Today, it reads steps, active energy and weight to show them there, and height to prefill goal setup (height is not saved). Nothing read from Health leaves the phone. No Health data is used for advertising, tracking or sold or shared with third parties.

Camera: used only to scan a package barcode or read a Nutrition Facts or Supplement Facts label on the device. No image is stored or sent. A rare camera check can also appear inside the hCaptcha challenge for an emailed sign-in code.

Notifications: optional reminders to log water or supplements, off until the user turns them on.

Privacy: the privacy manifest, the policy and the App Store privacy answers are in docs/privacy-manifest.md and PRIVACY.md.
```

## Claims boundary

The copy stays inside the roadmap. It does not say the app diagnoses, treats, coaches or scores anything, and it
does not claim that goals are healthy or recommended. The Medication log is off by default and a named-medication
feature, so the copy does not mention it. The reference-values line in the description describes published
reference intakes shown beside the day's totals (`docs/reference-intakes.md`), not advice.
