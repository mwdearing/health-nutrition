# App Store Connect metadata

Status: Draft for the first App Store release. Every claim below was checked against `README.md`, `PRIVACY.md`,
`docs/` and `ios/HealthNutrition/project.yml` at the commit this PR branched from. Re-check it when a feature
changes. Nothing here claims a score, advice or a medical effect, and the verb for adding an entry is "Log".

## Character counts

| Field | Characters | Limit |
| --- | --- | --- |
| Name | 26 | 30 |
| Subtitle | 28 | 30 |
| Promotional text | 167 | 170 |
| Keywords | 90 | 100 |
| Description | 2647 | 4000 |
| What's New | 324 | 4000 |
| Review notes | 2290 | 4000 |

Counts are Unicode characters as Python's `len` reports them, not counting the trailing newline. The keyword field counts the commas.

## Name and subtitle

- Name: `Health Nutrition: Food Log`
- Subtitle: `Log food, water, supplements`

The app's display name on the Home Screen is `HealthNutrition` (`CFBundleDisplayName`). Apple requires an
app name that no one else holds; if `Health Nutrition: Food Log` is taken, use `Health Nutrition Journal` (24) or `Health Nutrition Log` (20).

## Promotional text

Log food, drinks, water and supplements in one private journal. Scan a barcode or label, see your day against goals you set, and send it to Apple Health if you choose.

## Keywords

`calorie,macro,diet,meal,diary,supplement,vitamin,mineral,hydration,barcode,protein,tracker`

Apple indexes the name and subtitle too, so `log`, `water`, `nutrition` and the plural `supplements` are left out here. `food` is not in the list, and the singular `supplement` stays as a separate search form.

## Description

Health Nutrition is a private food, drink and supplement journal. Log what you have, see your day against goals you set, and keep it all on your phone.

LOG IT YOUR WAY
- Scan a package barcode (look-up in the community catalog needs an account), scan a Nutrition Facts or Supplement Facts label, search foods by name, or type it in.
- Log water with one tap on Today, or type another amount.
- Keep favorites, recent items and saved meals, and log them again in a tap.
- Build your own recipes and log a serving.
- Create your own products with the nutrition facts you enter.

SEE YOUR DAY
- Today shows calories, protein, carbohydrate and fat, plus a bar for every other nutrient you track, against goals you set. Set the goals yourself, or answer a few questions for a starting estimate you can change any time.
- The Diary lists every day by meal. Open any entry to fix the amount, time or day.
- Trends shows the last 7 days and 30-day averages from your own Diary. A day you did not log is shown as empty, not as zero.
- See vitamins and minerals for the day beside published reference intakes.
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
- Erase all data in Settings removes the journal and other app data on this device. It does not remove samples already written to Apple Health or shared catalog submissions.

PRIVATE BY DESIGN
- Your journal is stored on this device. The app has no ads and no analytics, and it does not track you across other apps or sites.
- Lookups send only what you submit: the barcode (to the community catalog, when signed in) or the words you search for (to the food databases, and to the project's server when signed in).
- An account is optional. Sign in with Apple or an emailed code only if you want to share product labels with the community catalog, look up a barcode there or search shared products by name.

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
| Unrestricted web access | No | The app only calls its fixed lookup services. It has no browser a person can use to visit pages. The emailed-code sign-in may show a human-check challenge from hCaptcha inside the app. |
| User-generated content | Yes | A signed-in person can share a product label's facts, which other people can find after owner review. There is no chat, posting, profile or free-text social feature. |
| Messaging or chat | No | None. |
| Parental controls, age assurance | No | None. |
| In-app purchases, ads | None | The app has neither. |

## Review notes

```text
Sign-in: none is needed to review the main flow. The reviewer does not need an account or a password. An account is optional. Everything works signed out except three things, which need an account: sharing product labels with the community catalog, looking up a barcode in that catalog, and searching shared products by name. Scanning a barcode still fills the barcode field without one. If you want to see it, Settings > Account offers Sign in with Apple, or an emailed one-time code (this may show an hCaptcha human check first). Delete account is in the same place.

First launch: a welcome screen appears once. Tap Get started. Nothing is requested at launch.

How to see the main flow: on Today, tap Add food, drink, or supplement, type a name and an amount, and save; tap a quick-add water button; open the Diary tab to see the entry. Search foods sends the words you submit (two or more characters) to Open Food Facts, and to USDA FoodData Central in builds that carry its key. When signed in, the same words also go to the project's server with the account, to search shared products.

Apple Health (HealthKit): off until the user taps Connect Apple Health in Settings. It is used only for nutrition logging: (1) it writes the nutrients and water of entries the user logs, and removes them again when the user edits or deletes an entry; (2) after the user connects, it reads the nutrient types it writes so Today's totals include nutrition other apps logged; (3) only if the user taps Show steps, activity and weight on Today, it reads steps, active energy and weight to show them there, and height to prefill goal setup (height is not saved). Nothing read from Health leaves the phone. No Health data is used for advertising, tracking or sold or shared with third parties.

Camera: used only to scan a package barcode or read a Nutrition Facts or Supplement Facts label on the device. No image is stored or sent by the app. A rare camera check can also appear inside the hCaptcha challenge for an emailed sign-in code; that check runs in hCaptcha's own view.

Notifications: optional reminders to log water or supplements, off until the user turns them on.

Privacy: the privacy manifest, the policy and the App Store privacy answers are in docs/privacy-manifest.md and PRIVACY.md.
```

## Before you submit

- Community catalog and sign-in: checked on 2026-11-04, so the copy stays. The \`testflight\` GitHub environment, which the signed build reads, holds \`SUPABASE_URL\` and \`SUPABASE_ANON_KEY\` (names only; the values were not read). The linked hosted project answers over HTTPS (a read-only request to its REST and Auth endpoints returned 401 "No API key found", which is the Supabase gateway responding), and the host records show the migrations applied through \`20261012000000\`. README.md still says the repository itself does not show a hosted service, because it cannot; this is the evidence. Not checked: that the secret's value is that same project's address.
- Confirm the name is free in App Store Connect.

## Claims boundary

The copy stays inside the roadmap. It does not say the app diagnoses, treats, coaches or scores anything, and it
does not claim that goals are healthy or recommended. The Medication log is off by default and a named-medication
feature, so the copy does not mention it. The reference-intakes line in the description describes published
reference intakes shown beside the day's totals (`docs/reference-intakes.md`), not advice.
