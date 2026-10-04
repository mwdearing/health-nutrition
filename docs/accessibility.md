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
- the image is built as `Image(decorative:)`, which says so itself;
- the image shares a control label with a `Text` that names it, because the
  text already names the control;
- the image is a `Label("…", systemImage:)`, which speaks its own title, or
  sits in the `icon:` closure of a `Label` whose title speaks for it, whether
  those closures are trailing or passed as `title:` and `icon:` arguments.

A control spelled out as `SwiftUI.Button` is read as the same control as
`Button`, so a module-qualified label closure names its image just the same.
Any other qualifier names a type of its own, so a custom view spelled
`Custom.Button` is not a SwiftUI control and the text inside its label closure
names nothing.

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

A modifier belongs to the view it is written on, so a label inside a nested
view names that view and leaves the one around it unnamed — whether the nested
view arrives in a trailing closure or in an argument:

```swift
Image("photo").overlay {         // unlabeled-image
    Image(systemName: "star").accessibilityLabel("New")
}

Image("photo").overlay(content: {  // unlabeled-image as well
    Image(systemName: "star").accessibilityLabel("New")
})
```

Text that is hidden from VoiceOver reads nothing aloud, so it does not name a
control either, and a `Picker`, `Menu` or `ControlGroup` closure with no
`label:` of its own holds content rather than a label — an option or an action
that has to be named in its own right:

```swift
Picker("Choose", selection: $choice) {
    Image(systemName: "a").tag(1)   // unlabeled-image
}
.accessibilityLabel("Choice")        // names the picker, not the option
```

Once that content has been passed as `content:`, a trailing closure is the
control's label, so the control's own name covers the image in it:

```swift
Menu(content: {
    Button("Delete") { remove() }
}) {
    Image(systemName: "ellipsis")
}
.accessibilityLabel("More")
```

Only a `content:` written as an argument of the control itself counts, so the
picker below is still left holding its options and the option image is still a
finding:

```swift
Picker("Choose", selection: binding(content: value)) {  // content: is the binding's
    Image(systemName: "a").tag(1)                      // unlabeled-image
}
.accessibilityLabel("Choice")
```

A modifier guarded by conditional compilation only counts when every
configuration that compiles the image compiles a name as well, so a label
written for `#if DEBUG` alone does not exempt an image that release builds leave
unnamed. The conditional is only followed when it is written directly after the
image, and an arm that starts with a view rather than a modifier ends the chain —
the traversal stops at the matching `#endif`, so nothing beyond the block is read
as a modifier of the image:

```swift
Image("one")   // unlabeled-image
#if DEBUG
Text("x")      // a sibling view, not a modifier of the first image
#endif
Image("two").accessibilityLabel("Two")
```

An arm that begins with another `#if` is descended into rather than read as a
view, because its nested arms are what the image is modified by in that
configuration. So the image below is named in every build, while the one after
it is not: the nested `#else` compiles `.padding()`, which names nothing.

```swift
Image("x")
#if os(iOS)
#if DEBUG
.accessibilityLabel("Debug")
#else
.accessibilityLabel("Release")
#endif
#else
.accessibilityLabel("Other")
#endif

Image("x")   // unlabeled-image
#if os(iOS)
#if DEBUG
.accessibilityLabel("Debug")
#else
.padding()
#endif
#else
.accessibilityLabel("Other")
#endif
```

Text hidden from VoiceOver reads nothing aloud, so it names nothing in the builds
that compile the hiding. It does still name the control in the builds where it
is visible, so the control below is named either way — a debug build reads
"Remove" and a release build reads "Delete" — while the one below it is a finding
in every build:

```swift
Button {} label: {
    Image(systemName: "trash")
    Text("Delete")
    #if DEBUG
    .accessibilityHidden(true)
    Text("Remove")       // names the button in debug builds
    #endif
}

Button {} label: {
    Image(systemName: "trash")
    Text("Delete")
    #if DEBUG
    .accessibilityHidden(true)   // unlabeled-image: the debug build names nothing
    #endif
}
```

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
label passed as an argument, the `Label` with title and icon closures, the
module-qualified control, the nested view in an `overlay` and in an
`overlay(content:)`, the hidden text, the `Picker` options, the `Menu` with a
`content:` argument and the conditional-compilation branches.