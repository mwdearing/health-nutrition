# Design tokens

The tokens live in `ios/NutritionCore/Sources/NutritionCore/NutritionTokens.swift` as pure data (opaque sRGB, no UI framework).
The app maps them to platform colors later. The direction is a white, clean light layout with teal and mint accents and a
dark mode that is designed to match it, not an inversion.

## Table

Every value is shown in both appearances. The 11 audited tokens come from the HealthRelay asset catalog and never change.
Semantic roles either name the existing token they equal, or are new values that need approval.

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
| background | #FFFFFF | #07222E | dark value equals RelayOnMint; light is white | proposed, needs Michael's approval |
| surface | #F2F2F7 | #0B3D4A | dark value equals the light value of RelayAccentInk | proposed, needs Michael's approval |
| border | #D1D5DB | #1F5663 | none | proposed, needs Michael's approval |
| textPrimary | #111827 | #F0F6FC | brand guide text colors | proposed, needs Michael's approval |
| track | #DCE7E9 | #1F5663 | none (dark equals border) | proposed, needs Michael's approval |
| accentTint | #E3F1F0 | #134B58 | none | proposed, needs Michael's approval |
| textSecondary | #6C6C70 | #AEAEB2 | RelaySecondaryText | existing: equals RelaySecondaryText |
| accent | #0F6B78 | #5EEAD4 | AccentColor | existing: equals AccentColor |
| success | #14592A | #A6E8B8 | RelayReadyInk | existing: equals RelayReadyInk |
| warning | #7A3E00 | #FFCB94 | RelayWaitingInk | existing: equals RelayWaitingInk |
| error | #8A1C14 | #FFB3AB | RelayFailedInk | existing: equals RelayFailedInk |

The rows marked proposed (background, surface, border, textPrimary) are the only additions in this change. They reuse
brand values where possible: the dark background is the dark end of the brand gradient, the dark surface is the other
gradient color, and the two text colors come from the brand guide. Nothing here is final until approved.

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
- The border role is a decorative separator. It is not text and does not carry meaning on its own, so it is not held to 4.5:1.
- `track` is the unfilled part of a goal bar and its hatch lines. It is decorative: the figure beside the bar always
  states the value, so the bar's low contrast against the background (1.26 light, 2.01 dark) never carries meaning alone.
  The filled part of the bar is the accent, which clears 3:1 on the track in both appearances.
- `accentTint` is the fill behind icon wells, kind tags and quiet capsules. Put `RelayAccentInk` or `textPrimary` on it.
  Do not put `textSecondary` on it in dark: that pair is 4.37:1.
- `track` and `accentTint` are kept in their own list (`NutritionTokens.design`) so the audited and semantic tables stay as approved.
- Do not add a token without a row in the table above and a passing contrast check.
