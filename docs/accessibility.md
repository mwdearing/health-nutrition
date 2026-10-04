# Accessibility

VoiceOver has to be able to name every control in this app. A glanceable
screen full of SF Symbols is only useful to VoiceOver when each symbol is
either named or deliberately silent, so the rule is enforced by
`scripts/lint_swift_sources.py` rather than left to review.

## The `unlabeled-image` rule

In the SwiftUI surfaces — `Sources/NutritionUI/**` in the package module and
everything the app target keeps under `ios/HealthNutrition/Sources/**` — an
`Image(...)` is a finding unless one of these holds in the same view expression:

- the image, or the `Button`/`Menu`/`Toggle` it is the label of, carries
  `.accessibilityLabel(...)`, whether it is written after the image or after the
  control's closing brace;
- the image or its control is marked `.accessibilityHidden(true)`, which is how
  a purely decorative symbol is declared;
- the image sits beside a `Text` in the same control label, because the text
  already names the control;
- the image is a `Label("…", systemImage:)`, which speaks its own title.

Findings are reported as `path:line: unlabeled-image: …`, on the line where the
`Image` starts.

## Marking a decorative image

Decorative art carries no meaning of its own, so it is hidden from the
accessibility tree rather than labelled. Hide the image itself:

```swift
HStack {
    Image(systemName: "drop").accessibilityHidden(true)
    Text("\(total) mL")
}
```

And label a control that is meaningful:

```swift
Button {
    remove(item)
} label: {
    Image(systemName: "trash")
        .foregroundStyle(TokenColors.error)
        .accessibilityHidden(true)
}
.accessibilityLabel(RecipeLabels.delete(title: item.title))
```

The icon stays silent and the button speaks, which is what a VoiceOver user
needs: one name per control, not two overlapping ones.

## Escape hatch

A line may opt out with the shared trailing comment, in case a symbol has to
stay visible but cannot be named inline:

```swift
let chartGlyph = Image(systemName: "waveform") // lint-allow: unlabeled-image
```

The exemption is line-scoped and shows up plainly in review; see
[Swift source lint](swift-lint.md) for how the mechanism works.

## Running the rule

```sh
python3 scripts/lint_swift_sources.py ios/NutritionCore
python3 scripts/lint_swift_sources.py ios/HealthNutrition
```

Both roots are expected to exit `0`. The behaviour is covered by
`scripts/tests/test_lint_swift_sources.py`, which builds synthetic view trees
for the icon-only `Button`, the labelled button, the decorative image and the
`Label` with a system image.