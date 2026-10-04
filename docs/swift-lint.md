# Swift source lint

`scripts/lint_swift_sources.py` keeps the Swift package honest about the rules the
app follows by convention rather than by compiler. It is a plain-stdlib Python
script, so it runs anywhere Python does and needs no toolchain beyond the linter.

## Running it

```sh
python3 scripts/lint_swift_sources.py ios/NutritionCore
```

The root argument defaults to `ios/NutritionCore`. Every finding is printed as
`path:line: rule: message`. The script exits:

- `0` when the tree is clean
- `1` when there is at least one finding
- `2` when the given root is not a directory

Comments and string contents are never inspected, so a colour or type name in
prose does not trip the lint. That covers `//` comments, block comments
including Swift's nested `/* /* */ */` form, plain and multi-line `"""`
literals, and extended literals such as `#"raw"#` or `##"""raw"""##`. The
expression inside a string interpolation *is* inspected, because it is compiled
Swift code: `"\(Double(value))"` is a finding while `"\(count) and Double in
prose"` is not.

Matching runs over the whole masked source rather than one line at a time, so a
prohibited call wrapped over several lines is caught. The finding is reported on
the line where the construct starts.

## Rules

| Rule | Scope | What is rejected |
| --- | --- | --- |
| `colour-literal` | `Sources/NutritionUI/**` | `Color(red:`, `UIColor(red:`, `NSColor(red:`, `Color(hex:` and `#RRGGBB` literals. `TokenColors.swift` is exempt: it is the one place that turns design-token values into colours. |
| `fixed-font` | `Sources/NutritionUI/**` | `.font(.system(size: ...))` and `Font.system(size: ...)`. Text uses Dynamic Type styles only, so it scales with the reader's settings. |
| `fixed-font-size` | `Sources/NutritionUI/**` and the app target's `Sources/**` | Any font pinned to a literal point size: `.font(.system(size: 14))`, `Font.system(size: 14)`, `.custom("Inter", fixedSize: 14)` and `Font.body.pointSize(14)`. A literal point size does not move when the reader changes their Dynamic Type setting, so the font has to scale on its own instead: a text style such as `.headline` or `.system(.body, design: .rounded)`, or `.custom("Inter", size: 14)`, which SwiftUI scales with the body text style. A size that is not a literal is fine, since one read from a `@ScaledMetric` property already tracks the reader's settings, and a `relativeTo:` argument of the font call itself relates the size to a text style. The arguments are read from the call's own bracket list, so a font wrapped over several lines is judged whole and a `relativeTo:` inside a nested call, as in `Font.custom(resolveName(relativeTo: locale), fixedSize: 14)`, does not exempt it; the finding lands on the line the font call starts on. `.custom(` and `.pointSize(` count only where they build or adjust a font, spelled on `Font` or written inside `.font(...)`, so `Widget.custom(name: "compact", size: 14)` is left alone. A `.font(.system(size:))` call is reported by both `fixed-font` and `fixed-font-size`. |
| `forbidden-import` | `Sources/NutritionUI/**`, `Sources/NutritionJournal/**` | `import HealthKit`, `import Network` and any use of `URLSession`. Declaration-kind and attributed forms count too, so `import class HealthKit.HKHealthStore` and `@_implementationOnly import Network` are rejected as well. These layers stay offline and free of HealthKit; providers own both. |
| `binary-float` | `Sources/NutritionDomain/**`, `Sources/NutritionJournal/**` | The `Double` and `Float` types, and untyped floating-point literals such as `0.1` or `1e-3`, which Swift would infer as `Double`. Quantities use `Decimal` so serving arithmetic does not drift. |

Layers outside the scopes above are not checked for those rules, so
`Sources/NutritionProviders/**` may legitimately use `URLSession`, `Network`
and floating point conversions.

## Allowing a finding

Sometimes a line has a good reason to break a rule. End the line with a
`lint-allow` comment naming the rule:

```swift
let chartTint = Color(hex: "#FF0000") // lint-allow: colour-literal
```

The exemption applies only to that line and only to the rules named. Multiple
rules can be listed, separated by commas or spaces. Use the mechanism
deliberately; no Swift source in the repository relies on it today, so any new
occurrence shows up plainly in review.

## Tests and CI

`scripts/tests/test_lint_swift_sources.py` builds synthetic Swift trees in a
temporary directory and asserts that each rule fires with the right file and
line, that comments and string contents stay silent, that `TokenColors.swift` is
exempt, that `lint-allow` works, and that a clean tree exits 0. It also covers
the trickier masking cases: prohibited calls split across lines, declaration-kind
imports, code inside string interpolations, nested block comments, extended
string delimiters and inferred floating-point literals. The font rules have their
own cases: a `.custom` font with `fixedSize:` and with a `relativeTo:` that
belongs to a nested call, the `pointSize` modifier on a Font, a size read from a
property rather than written as a literal, a `.custom(` on another type, text
styles that name no size at all, a font call wrapped over several lines, and a
`lint-allow` naming one font rule without silencing the other.

```sh
python3 -m pytest scripts/tests/test_lint_swift_sources.py
```

Both the lint and its tests run on every pull request via
`.github/workflows/swift-lint.yml`.

## The SwiftSyntax spike

`tools/swift-syntax-lint/` reimplements `unlabeled-image` and `fixed-font-size` on
a SwiftSyntax tree instead of with regular expressions, to find out whether the
same rules are simpler and more correct that way. It enforces nothing: this script
still decides what the repository has to satisfy, and the spike's CI job runs with
`continue-on-error: true`.

The two are run over the same snippets, which
`scripts/export_lint_corpus.py` exports from the cases in
`scripts/tests/test_lint_swift_sources.py` into
`tools/swift-syntax-lint/Tests/corpus.json`. The package's test target runs every
case through its own rules and reports the agreement, which
`tools/swift-syntax-lint/README.md` records. The decision this feeds is
[adr/0003-swift-syntax-lint.md](adr/0003-swift-syntax-lint.md), which is Proposed.