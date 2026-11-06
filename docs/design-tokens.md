# Design tokens

The tokens live in `ios/NutritionCore/Sources/NutritionCore/NutritionTokens.swift` as pure data (opaque sRGB, no UI framework).
The app maps them to platform colors later. The direction is a white, clean light layout with teal and mint accents and a
dark mode that is designed to match it, not an inversion.

## Table

Every value is shown in both appearances. The 11 audited tokens come from the HealthRelay asset catalog and never change.
Semantic roles either name the existing token they equal, or are new values approved on 2026-11-06.

| Token | Light | Dark | HealthRelay source | Status |
|---|---|---|---|---|
| AccentColor | #0F6B78 | #5EEAD4 | AccentColor asset | existing |
| RelayAccentInk | #0B3D4A | #5EEAD4 | RelayAccentInk asset | existing |
| RelayMint | #5EEAD4 | #5EEAD4 | RelayMint asset | existing |
| RelayOnMint | #07222E | #07222E | RelayOnMint asset | existing |
| RelayReadyInk | #14592A | #A6E8B8 | RelayReadyInk asset | existing |
| RelayReadyTint | #D6F2DE | #14331E | RelayReadyTint asset | existing |
| RelayWaitingInk | #7A3E00 | #FFCB94 | RelayWaitingInk asset | existing |
| RelayWaitingTint | #FFE6CC | #3A2610 | RelayWaitingTint asset | existing |
| RelayFailedInk | #8A1C14 | #FFB3AB | RelayFailedInk asset | existing |
| RelayFailedTint | #FFDCD8 | #3D1512 | RelayFailedTint asset | existing |
| RelaySecondaryText | #6C6C70 | #AEAEB2 | RelaySecondaryText asset | existing |
| background | #FFFFFF | #07222E | dark value equals RelayOnMint; light is white | approved 2026-11-06 |
| surface | #F2F2F7 | #0B3D4A | dark value equals the light value of RelayAccentInk | approved 2026-11-06 |
| border | #86868B | #5B98A4 | 3.62:1 on background, 3.25:1 on surface (light); 5.07:1 and 3.63:1 (dark) | approved 2026-10-18 |
| textPrimary | #111827 | #F0F6FC | brand guide text colors | approved 2026-11-06 |
| track | #DCE7E9 | #1F5663 | none | approved 2026-11-06 |
| accentTint | #E3F1F0 | #134B58 | none | approved 2026-11-06 |
| page | #F2F2F7 | #07222E | screen background behind cards | approved 2026-11-06 |
| card | #FFFFFF | #0B3D4A | cards and grouped rows | approved 2026-11-06 |
| hero | #07222E | #11505F | Today hero and deep teal feature cards; the dark value is lighter than card | approved 2026-11-06 |
| heroText | #FFFFFF | #FFFFFF | primary text on hero | approved 2026-11-06 |
| heroSecondaryText | #9FC5CC | #9FC5CC | secondary text on hero | approved 2026-11-06 |
| heroTrack | #17464C | #1F6C74 | ring and bar track on hero (mint at 18% over hero, flattened) | approved 2026-11-06 |
| macroProtein | #0F6B78 | #5EEAD4 | protein bar and legend | approved 2026-11-06 |
| macroCarbs | #B45309 | #FBBF24 | carbs bar and legend | approved 2026-11-06 |
| macroFat | #2563EB | #93B4FF | fat bar and legend | approved 2026-11-06 |
| textSecondary | #6C6C70 | #AEAEB2 | RelaySecondaryText | existing: equals RelaySecondaryText |
| accent | #0F6B78 | #5EEAD4 | AccentColor | existing: equals AccentColor |
| success | #14592A | #A6E8B8 | RelayReadyInk | existing: equals RelayReadyInk |
| warning | #7A3E00 | #FFCB94 | RelayWaitingInk | existing: equals RelayWaitingInk |
| error | #8A1C14 | #FFB3AB | RelayFailedInk | existing: equals RelayFailedInk |

The five roles that were proposed (background, surface, textPrimary, track, accentTint) were approved on 2026-11-06,
together with the nine roles for the branded-hero layout (page through macroFat). They reuse brand values where
possible: the dark background is the dark end of the brand gradient, the dark surface is the other gradient color, and
the two text colors come from the brand guide. On hero the macro colors always use their dark values.

## Contrast rule

Normal text must reach a contrast ratio of at least 4.5:1 against the color it sits on, in light and in dark.
Large text and meaningful graphics need at least 3:1. The host checks every text and background pair with a contrast
script, and the unit tests check the same pairs with the WCAG 2.x formula.

Checked pairs (light / dark ratio):

| Foreground on background | Light | Dark |
|---|---|---|
| textPrimary on background | 17.74 | 15.10 |
| textPrimary on surface | 15.90 | 10.84 |
| textSecondary on background | 5.23 | 7.44 |
| textSecondary on surface | 4.69 | 5.33 |
| accent on background | 6.19 | 11.11 |
| accent on surface | 5.54 | 7.97 |
| success on background | 8.43 | 11.63 |
| success on surface | 7.55 | 8.34 |
| warning on background | 8.34 | 11.13 |
| warning on surface | 7.48 | 7.99 |
| error on background | 9.30 | 9.62 |
| error on surface | 8.34 | 6.90 |
| textPrimary on page | 15.90 | 15.10 |
| textPrimary on card | 17.74 | 10.84 |
| textSecondary on page | 4.69 | 7.44 |
| textSecondary on card | 5.23 | 5.33 |
| accent on page | 5.54 | 11.11 |
| accent on card | 6.19 | 7.97 |
| success on page | 7.55 | 11.63 |
| success on card | 8.43 | 8.34 |
| warning on page | 7.48 | 11.13 |
| warning on card | 8.34 | 7.99 |
| error on page | 8.34 | 9.62 |
| error on card | 9.30 | 6.90 |
| heroText on hero | 16.44 | 8.99 |
| heroSecondaryText on hero | 8.87 | 4.85 |
| macroProtein, macroCarbs, macroFat on card (graphic, needs 3:1) | 6.19 / 5.02 / 5.17 | 7.97 / 7.06 / 5.74 |
| RelayMint on hero (graphic, needs 3:1) | 11.11 | 6.08 |
| macroCarbs dark on hero (graphic, needs 3:1) | 9.85 | 5.38 |
| macroFat dark on hero (graphic, needs 3:1) | 8.00 | 4.37 |
| hero against card (dark appearance) | n/a | 1.31 |
| RelayReadyInk on RelayReadyTint | 7.07 | 9.76 |
| RelayWaitingInk on RelayWaitingTint | 6.93 | 9.71 |
| RelayFailedInk on RelayFailedTint | 7.30 | 9.35 |
| RelayOnMint on RelayMint | 11.11 | 11.11 |
| accent fill on track (graphic, needs 3:1) | 4.90 | 5.52 |
| RelayAccentInk on accentTint | 10.17 | 6.53 |
| textPrimary on accentTint | 15.30 | 8.87 |
| accent on accentTint | 5.33 | 6.53 |

## Usage notes

- Never use RelayMint as text on a light surface: mint on white is only 1.48:1. Mint is a fill color, with RelayOnMint on top.
- In dark mode the accent is mint, which reads at 11.11:1 on the dark background.
- The border role is the input outline of a field. It is a graphic that marks where the field is, so it is held to 3:1 against the background and the surface in both appearances (approved 2026-10-18).
- `track` is the unfilled part of a goal bar and its hatch lines. It is decorative: the figure beside the bar always
  states the value, so the bar's low contrast against the background (1.26 light, 2.01 dark) never carries meaning alone.
  The filled part of the bar is the accent, which clears 3:1 on the track in both appearances.
- `accentTint` is the fill behind icon wells, kind tags and quiet capsules. Put `RelayAccentInk` or `textPrimary` on it.
  Do not put `textSecondary` on it in dark: that pair is 4.37:1.
- `track` and `accentTint` are kept in their own list (`NutritionTokens.design`) so the audited and semantic tables stay as approved.
- The nine layout roles are kept in `NutritionTokens.layout`. Screens on the new layout use `page` and `card`; `background` and `surface` stay for anything not yet moved.
- Do not add a token without a row in the table above and a passing contrast check.
