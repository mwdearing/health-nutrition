# Visual redesign: branded hero

Status: approved by the owner on 2026-11-06, including the color roles and the five proposed tokens named under Color. Nothing here is built yet. The owner chose the direction (B, "branded
hero") from a set of mock-ups on 2026-11-06; this document turns that choice into something a builder can plan from.
Choices marked **owner decision** wait for an answer. Choices marked *builder's call* were made by the author and can
be changed during planning without asking.

## Why

The owner's words: the app "all just looks like plain text on a screen and outdated Android design". The new icon (a
mint lowercase n with a white leaf on deep teal, `docs/app-icon.svg`) sets the look the rest of the app should match.
The target is an app that looks as if Apple designed it for iOS 27: current materials, clear hierarchy, the system
font, charts and motion, with the brand carried by color and content rather than by custom chrome. This ships in the
first App Store release. The owner accepted that the submission date moves for it, so the plan covers every step
below rather than a cut list.

What makes the current app read as plain text (from a review of the source at 86efece9):

- Most screens are stock `List` or `Form` with the background hidden and white rows on white, so nothing separates one
  group from the next. Cards appear on only five screens.
- `.footnote` is used 178 times and `.largeTitle` 3 times; only the Today total carries display weight.
- The brand mint appears only on the floating Add capsule. There is no ring (docs/today-screen.md describes one, the
  code draws text), one chart, no imagery.
- Patterns that read as another platform: a floating pill button on every tab, a snackbar-style undo toast, circular
  icon wells, a centered title drawn inside the content with the navigation title hidden.
- The `AccentColor` asset is #167A5A / #4FBA9C, not the documented #0F6B78 / #5EEAD4, so stock controls and explicitly
  tinted controls show two different greens.
- Widgets and the Watch app use system gray only; they cannot reach the tokens.

## Goals

1. **Native chrome.** Tab bar, toolbars, search fields, sheets, menus and buttons are the system's iOS 26 Liquid Glass
   components. Nothing in the navigation layer is drawn by hand.
2. **Brand in the content.** Color lives inside the scrolling content, following Apple's guidance for branding on
   iOS 26 and later: a deep teal hero on Today with a mint calorie ring, and deep teal feature cards elsewhere. The
   glass controls pick up that color as content scrolls under them.
3. **Hierarchy.** White cards on the grouped background in light mode; teal cards on deep teal in dark mode. Large
   titles, real section headers, fewer footnotes.
4. **A visual vocabulary.** A calorie ring, labeled macro bars, Swift Charts for trends, rounded-square icon wells with
   SF Symbols, rounded numerals for figures.
5. **Motion with purpose.** Spring animations on value changes, a zoom transition into an entry, symbol effects on
   confirmations, all off when Reduce Motion is on.
6. **One family across surfaces.** Widgets, Lock Screen accessories and the Watch app use the same ring, colors and
   type.

## Non-goals

- No change to what the app does: logging, calculations, goals, sync, HealthKit, privacy, export and import contracts,
  reminders, medication and supplement behavior all stay as they are. Copy changes only where a label is unified
  (below).
- No custom fonts, illustrations or photography.
- No iPad-specific layouts. iPad keeps working with the same screens at a readable width.
- No change to the 11 audited tokens.

## Anti-goals (a failure even if it builds)

- Text that becomes hard to read over glass, or meaning carried by color alone.
- Anything that breaks Dynamic Type up to the largest accessibility size, VoiceOver, Reduce Transparency, Increase
  Contrast or Reduce Motion.
- A dark mode that looks inverted rather than designed.
- Hand-built copies of system controls (a custom tab bar, a custom segmented control, a custom sheet).
- Lost or renamed accessibility identifiers that tests and automation depend on, unless the test moves with them.
- A slower launch or janky scrolling (the ring and charts render with the screen, no layout passes on every frame).

## The look

The mock-ups (shared with the builder outside the repository) are the reference for proportion and feel; the values
below are the reference for numbers. Light and
dark are both first-class.

### Color

Existing tokens keep their names and values, `background` and `surface` included; screens that move to the new
layout use `page` and `card` instead, and the older roles stay for anything that still needs them. New semantic roles (all opaque sRGB, like the rest of `NutritionTokens.swift`):

| Token | Light | Dark | Use |
|---|---|---|---|
| `page` | #F2F2F7 | #07222E | Screen background behind cards |
| `card` | #FFFFFF | #0B3D4A | Cards and grouped rows |
| `hero` | #07222E | #11505F | Today hero and deep teal feature cards (in dark, lighter than `card` so feature cards stand out) |
| `heroText` | #FFFFFF | #FFFFFF | Primary text on `hero` |
| `heroSecondaryText` | #9FC5CC | #9FC5CC | Secondary text on `hero` |
| `heroTrack` | #17464C | #1F6C74 | Ring and bar track on `hero` (mint at 18% over `hero`, flattened) |
| `macroProtein` | #0F6B78 | #5EEAD4 | Protein bar and legend |
| `macroCarbs` | #B45309 | #FBBF24 | Carbs bar and legend |
| `macroFat` | #2563EB | #93B4FF | Fat bar and legend |

On `hero` the macro colors always use their dark values. Mint (`RelayMint`) is a fill, as today: the ring, the Add
button and the selected day; text on it is `RelayOnMint`.

Contrast, measured with the WCAG 2.x formula (the unit tests add these pairs):

| Pair | Ratio |
|---|---|
| heroText on hero (light / dark) | 16.44 / 8.99 |
| heroSecondaryText on hero (light / dark) | 8.87 / 4.85 |
| RelayMint on hero (light / dark) | 11.11 / 6.08 |
| macroCarbs dark on hero (light / dark) | 9.85 / 5.38 |
| macroFat dark on hero (light / dark) | 8.00 / 4.37 |
| macroProtein, macroCarbs, macroFat light on card #FFFFFF | 6.19 / 5.02 / 5.17 |
| textPrimary on page (light), #111827 light / #F0F6FC dark | 15.90 |
| textSecondary on page (light), #6C6C70 light / #AEAEB2 dark | 4.69 |
| accent on page (light) | 5.54 |

The three macro colors are close in lightness, so every bar carries its label and value; color is never the only
cue.

`AccentColor.colorset` changes to #0F6B78 / #5EEAD4 so stock controls match the tokens, and a test compares the asset
with the token.

**Owner decision (token approval).** `docs/design-tokens.md` requires the owner's approval for new tokens and still
lists `background`, `surface`, `textPrimary`, `track` and `accentTint` as proposed. Approving this document approves
those five at their current values and the nine new rows above.

### Type

- System text styles only (the lint stays). Figures use the rounded design (`.fontDesign(.rounded)`) with tabular
  digits.
- Large navigation titles on every tab root. Section headers use `.title3` bold or `.headline`, not footnotes.
  Supporting lines use `.subheadline`; `.footnote` is kept for genuine fine print.

### Shape, spacing, depth

- Cards: continuous corner radius 22, padding 16, 12 between cards, 16 from the screen edge. Small tiles: radius 18.
- Icon wells: 30 to 36 pt rounded squares (radius about 28% of the side) in `accentTint` with an `accent` symbol.
  Settings rows use the system's colored-tile convention.
- No drop shadows on cards; separation comes from the page and card colors. Glass carries its own depth.

### Components (new or reworked, shared across screens)

- `CalorieRing`: progress ring with the remaining figure in the center; sizes scale with Dynamic Type
  (`@ScaledMetric`); VoiceOver reads "1,240 calories left of 2,300".
- `MacroBar`: label, "82 / 140 g", a 6 pt capsule bar.
- `HeroCard`: the deep teal container (Today hero, Diary week strip, Trends calories card, Library highlight, Settings
  profile card).
- `Card`, `IconWell`, `SectionHeader`, `StatTile` (water and supplements tiles).
- Existing `PrimaryCapsule`, `QuietCapsule`, `KindTag`, `InlineNotice`, `EmptyState` restyled to the new tokens; the
  undo toast becomes a glass capsule above the tab bar.

## Screens

Each screen keeps its current content and behavior; only presentation changes.

- **Tab bar.** System `TabView` with four tabs in this order: Today (`sun.max`), Diary (`book.closed`), Library
  (`square.grid.2x2`), Trends (`chart.bar`). The Add action is a separate mint circle trailing the tab bar, the way
  iOS 26 shows a separated tab; it opens the Log sheet from any tab and does not change the selected tab. This
  replaces the floating "Add food, drink, or supplement" capsule; the button keeps that accessibility label. *How it
  is built (a separated tab whose selection is intercepted, or another system mechanism) is the builder's call, as
  long as it is a system component and looks like the mock-up.*
- **Settings.** Stays a sheet opened from a glass toolbar button on every tab. Top: a hero card for the existing
  Daily goals row. Then the existing sections (Units and logging, Connections, Privacy, Your data, About) as inset
  grouped cards, each row with a colored icon tile.
- **Today.** Hero (large title "Today" and date in the navigation bar over the hero, calorie ring, Goal / Food /
  Exercise, three macro bars), then Water and Supplements tiles, then the Medications tile when the medication log is
  on, a Meals card (breakfast, lunch, snack, dinner with totals; an empty meal shows an add button), the weight
  chart and the vitamins and minerals summary. The first-day checklist and goal prompt appear as cards in the same
  style.
- **Diary.** Large title, a deep teal week strip (day letters, dates, the selected day in mint, a dot on days with
  entries, the day's calories, protein and water), then one card per meal with its total and its entries (name,
  serving, calories). Entry detail opens with a zoom transition and is an inset grouped form in the new style.
- **Log sheet (Add).** Large-detent sheet with a grabber: Cancel, title, the meal choice the flow already has, the
  search field, the four existing quick actions (barcode, label, Type it in, Amounts only) as tiles, then the recent
  items with a mint add button on each row. The intake form, quick add, label capture and barcode sheets
  follow the same card and form style.
- **Library.** Large title, search field, the existing segments (Favorites, Recent, Products, Recipes) as a glass
  segmented control or chips, saved meals as a horizontal row of cards (the first in `hero`) where the Library shows
  them today, rows as cards.
  Supplement stack, medication log, recipe list and detail, custom product editor and community search use the same
  cards, headers and icon wells.
- **Trends.** Large title, a deep teal calories card (average, difference from goal,
  Swift Charts bars with a goal rule), a macros card (stacked bar plus legend), a weight card (line chart in pounds),
  and the vitamins and minerals card with warning chips. The 7-day bars in Insights move to Swift Charts.
- **Goals, goal setup, account, connections and privacy, welcome, sign-in.** Inset grouped forms and cards in the new
  style; Welcome uses the hero for its first card and the icon's mark.
- **Widgets.** Small: ring and remaining calories on `hero`. Medium: ring, macro bars and water. Lock Screen
  accessories keep the system's rendering (the accessory families draw in the system tint). Widgets and the Watch get
  the colors they need through their own asset catalog entries, since they do not link NutritionCore; a test keeps
  those entries equal to the tokens.
- **Watch.** Title, ring with remaining calories, then the day's macros, from the snapshot the Watch already
  receives; complications keep their families with the ring style.

### Content rule

Where this document or the mock-ups show content the app does not have today, the current content wins: the redesign
changes presentation only. The mock-ups were drawn before this check and show a few things that are not in the app;
they are listed under Follow-ups and are not part of this work.

### Label clean-up

The tab says "Diary" and the screen says "Journal"; the Trends tab opens a row called "Insights". Everything that
names the Diary tab says "Diary", and Trends keeps "Trends" with Insights as a section inside it. *Builder's call
on any further wording, within the existing copy rules.*

## Platform

**Minimum iOS: raised to iOS 26 and watchOS 26** (owner decision, 2026-11-06). The app and its widget extensions
move from iOS 18.0 to 26.0 and the Watch app and its complications from watchOS 11.0 to 26.0, so every Liquid Glass
API (`glassEffect`, glass button styles, the separated tab, scroll edge effects, tab bar minimizing) is used directly,
with no availability checks or fallback look. People on iOS 25 or earlier cannot install the app.

CI builds with Xcode 26.6 (iOS 26.5 SDK), which has every API this design uses. Running on iOS 27 adds Apple's 2026
glass refinements without a rebuild.

## Accessibility

- Dynamic Type to AX5: the hero stacks vertically, the ring and tiles scale with `@ScaledMetric`, rows wrap instead of
  truncating.
- VoiceOver: the ring, each macro bar, each chart and each tile has one combined label with its values; charts expose
  audio graphs where Swift Charts provides them.
- Reduce Transparency and Increase Contrast: system glass adapts; custom surfaces are opaque already.
- Reduce Motion: springs and the zoom transition fall back to fades.
- Touch targets at least 44 pt.

## Constraints the builder inherits

- Tests first (AGENTS.md): each change starts from a failing test, and tests that pin layout or copy move in the same
  change as the layout:
  - `TodayCentringUITests` (identifiers `todayHeader`, `todayDate`, `calorieFoodBurnedRow`; the navigation bar
    titled "Today" with no duplicate in the content);
  - the AddSearch UI tests that tap strings and tabs ("Get started", "Log", "Search foods", "Type it in", the Library
    tab);
  - `AppStoreScreenshotUITests` (tabs by label);
  - `scripts/tests/test_add_capsule_placement.py` (rewritten for the new Add button);
  - `NutritionTokensTests` (new rows and contrast pairs added; the audited values untouched).
- `scripts/lint_swift_sources.py` rules stay: no color literals, no fixed fonts or sizes, every image labeled.
- The design-system pipeline (`build_design_system.py --check`, light and dark screenshots per screen) passes, and its
  screenshots are regenerated.
- The App Store screenshots are retaken from the new build.

## Delivery

*Builder's call, as a starting point for the plan.* One pull request per step, each reviewed and green before the
next starts:

1. Foundation: tokens and tests, `AccentColor` fix, deployment targets to iOS 26 and watchOS 26, shared components.
2. Chrome: tab bar and Add button, toolbars, Settings sheet, undo toast.
3. Today.
4. Diary and entry detail.
5. Log sheet and the add flows.
6. Library and its sub-screens.
7. Trends and Insights (Swift Charts).
8. Settings, goals, account, privacy, welcome, sign-in.
9. Widgets and Watch.
10. Screenshots (design system and App Store), docs (`design-tokens.md`, `today-screen.md`, screen docs).

## Follow-ups (not in this work)

Shown in the mock-ups but new behavior, so each needs its own design: a Week / Month / 6 months range on Trends, a
"Log water" button on the Watch (needs a Watch-to-phone write), Supplements and Medications as Library sections, and a
Saved meal quick action in the Log sheet.

## Left to the builder

Component APIs and file layout, exact spacing within the scale above, animation curves, SF Symbol choices for the
mock-ups' icons, chart axes and marks, the order of work inside each step, and how the Add button is built (within the
constraint above).
