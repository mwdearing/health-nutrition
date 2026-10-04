# Accessibility

VoiceOver has to be able to name every control in this app. A glanceable
screen full of SF Symbols is only useful to VoiceOver when each symbol is
either named or deliberately silent, so the rule is enforced by
`scripts/lint_swift_sources.py` rather than left to review.

## The `unlabeled-image` rule

In the SwiftUI surfaces — `Sources/NutritionUI/**` in the package module and
everything the app target keeps under `ios/HealthNutrition/Sources/**` — an
`Image(...)` is a finding unless one of these holds:

- the image carries `.accessibilityLabel(...)`, whether it is written on the
  image itself or on the `Button`/`Menu`/`Toggle` the image is the label of,
  the latter even when it comes after the control's closing brace;
- the image or that control is marked `.accessibilityHidden(true)`, which is
  how a purely decorative symbol is declared;
- the image shares a control label with a `Text` that names it, because the
  text already names the control;
- the image is a `Label("…", systemImage:)`, which speaks its own title.

An enclosing layout is not a control, so text elsewhere in the same `VStack`
names nothing:

```swift
VStack {
    Text("Caption")          // names the caption, not the image below
    Image(systemName: "person")  // unlabeled-image
}
```

Nested layouts are climbed through, so the label on a control still names an
image buried in its label closure:

```swift
Button { toggle() } label: {
    HStack {
        Image(systemName: "star")  // named by the button
    }
}
.accessibilityLabel("Favorite")
```

A modifier guarded by conditional compilation only counts when every
configuration that compiles the image compiles a name as well, so a label
written for `#if DEBUG` alone does not exempt an image that release builds leave
unnamed.

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

Both roots are expected to exit `0`. A run over the package root also covers the
app target beside it, so the single invocation CI runs enforces both surfaces.
`scripts/tests/test_lint_swift_sources.py` covers the rule itself with synthetic
view trees for the icon-only `Button`, the labelled button, the decorative
image, the `Label` with a system image, the unlabelled layout caption, the
conditional-compilation branches and the module scope.