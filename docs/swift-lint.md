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

Comments (`//` and `/* ... */`) and the contents of string literals, including
multi-line `"""` literals, are never inspected. Only real code is matched, so a
colour or type name mentioned in prose does not trip the lint.

## Rules

| Rule | Scope | What is rejected |
| --- | --- | --- |
| `colour-literal` | `Sources/NutritionUI/**` | `Color(red:`, `UIColor(red:`, `NSColor(red:`, `Color(hex:` and `#RRGGBB` literals. `TokenColors.swift` is exempt: it is the one place that turns design-token values into colours. |
| `fixed-font` | `Sources/NutritionUI/**` | `.font(.system(size: ...))` and `Font.system(size: ...)`. Text uses Dynamic Type styles only, so it scales with the reader's settings. |
| `forbidden-import` | `Sources/NutritionUI/**`, `Sources/NutritionJournal/**` | `import HealthKit`, `import Network` and any use of `URLSession`. These layers stay offline and free of HealthKit; providers own both. |
| `binary-float` | `Sources/NutritionDomain/**`, `Sources/NutritionJournal/**` | The `Double` and `Float` types. Quantities use `Decimal` so serving arithmetic does not drift. |

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
exempt, that `lint-allow` works, and that a clean tree exits 0.

```sh
python3 -m pytest scripts/tests/test_lint_swift_sources.py
```

Both the lint and its tests run on every pull request via
`.github/workflows/swift-lint.yml`.