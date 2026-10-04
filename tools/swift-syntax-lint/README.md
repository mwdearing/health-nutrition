# swift-syntax-lint (spike)

A spike for [#68](https://github.com/openfoodfacts/health-nutrition-wt-nr02e/issues/68):
do the `unlabeled-image` and `fixed-font-size` rules get simpler and more
correct when they read a SwiftSyntax tree instead of running regular expressions
over masked source?

Nothing here enforces anything. The Python lint in `scripts/lint_swift_sources.py`
still decides what the repository has to satisfy, and the CI job for this package
runs with `continue-on-error: true`, so a disagreement here never blocks a pull
request. The decision this spike feeds is recorded in
[`docs/adr/0003-swift-syntax-lint.md`](../../docs/adr/0003-swift-syntax-lint.md).

## What is in here

| Path | What it is |
| --- | --- |
| `Sources/SwiftSyntaxLint/` | The two rules, as a library, plus the shared plumbing: finding files, choosing the scope, reading `lint-allow` comments |
| `Sources/swift-syntax-lint/` | The command line, which prints `path:line: rule: message` and exits 0, 1 or 2 exactly as the Python lint does |
| `Tests/corpus.json` | The snippets and expected findings both implementations are run over. Written by `scripts/export_lint_corpus.py`, not by hand |
| `Tests/SwiftSyntaxLintTests/` | Runs every corpus case through these rules and reports the agreement |

The rules walk the tree with a `SyntaxVisitor`. The `unlabeled-image` rule reads
the chain of modifiers above an image, the control whose label closure the image
sits in, and the `Text` calls of that label; `accessibilityHidden(true)` hides
rather than names. `fixed-font-size` reads the arguments of the font call itself,
so a `relativeTo:` written inside a nested call belongs to that nested call
without any bracket-depth bookkeeping.

Conditional compilation is handled through `IfConfigDeclSyntax`. A name counts
only when every configuration that compiles the image also compiles a name, and
`ConditionalWorld` does that arithmetic over the arms the parser found rather
than over `#if` lines.

## Running it

```sh
# Build and run the corpus test.
swift build
swift test

# The tool over the two SwiftUI surfaces, the same arguments the Python lint
# takes. This package depends on swift-syntax, so the first build is a
# compilation of the parser and takes a few minutes; later builds are seconds.
swift run swift-syntax-lint ios/NutritionCore
swift run swift-syntax-lint ios/HealthNutrition

# The Python side of the comparison, which needs no toolchain.
python3 scripts/export_lint_corpus.py --check
python3 scripts/lint_swift_sources.py ios/NutritionCore
```

macOS only: swift-syntax is built from source and needs the macOS toolchain.
The Linux CI job for the Python lint is unaffected.

## The corpus

`scripts/export_lint_corpus.py` reads the cases out of
`scripts/tests/test_lint_swift_sources.py`, keeps the ones that exercise these two
rules, writes their snippets to `Tests/corpus.json`, and checks each one against
the lint that wrote it, so a corpus entry can never disagree with the Python lint
it came from. Run it after changing a case in that test file:

```sh
python3 scripts/export_lint_corpus.py
```

`swift test` then runs every case through these rules and prints how many agree
and which do not.

## Agreement with the Python rules

The measurement is made by `swift test`, which runs every corpus case through
these rules and prints the agreement rate together with each disagreement. The
figures below are from the CI run of this branch, on the commit before the round
of fixes described at the end.

**Before the fixes: 46 of 55 cases agree (83%).**

The corpus is 55 cases: 30 that expect at least one finding and 25 that expect
none. A corpus of clean cases matters as much as a corpus of reported ones, since
a rule that started reporting everything would agree on none of them.

| Scope | Cases | Agreeing | Disagreeing |
| --- | --- | --- | --- |
| whole corpus | 55 | 46 | 9 |

Of the 30 reporting cases, 20 expect `unlabeled-image` and 16 expect
`fixed-font-size`; six expect both. Every disagreement CI named is about an
image, so `fixed-font-size` agreed on every case it is exercised by. That fits
the fixes below: all of them are in how the tree walks to a modifier or a
closure, and the font rule reads its arguments from the call it is already
standing on.

The nine disagreements CI named, and what became of each:

| Disagreement | Cause | Fix |
| --- | --- | --- |
| The app target was not linted (2 cases) | `findings(overRoots:)` linted exactly the roots it was handed, so a run over the package root missed `../HealthNutrition` unless the caller expanded it first | The sibling expansion now happens inside `findings(overRoots:)`, so no caller can forget it |
| Decorative and `accessibilityHidden` images (2 cases) | The first step of a modifier chain landed on the bare `MemberAccessExpr`, which carries no arguments, so `.accessibilityHidden(true)` was read as if it took no argument at all | A chain step now looks one level further for the call that wraps the member access, so its arguments are read with it |
| A label present in every `#if` branch (3 cases) | An arm written in expression position holds a postfix expression rather than a statement list, so those arms yielded nothing and the label went unseen | Both arm forms are read, so a label in every clause of an `IfConfigDeclSyntax` is found |
| A hidden `Text` did not stop naming its control (2 cases) | Same chain-step cause: the `.accessibilityHidden(true)` on the text was never seen, so hidden text still named the control | Fixed by the same chain-step change |
| A custom-qualified control (1 case) | The tree and the Python rule disagree about which control the image is in | **Not fixed.** Left as a known difference; see below |

### After the fixes

Not yet measured: the run that reports the new figure has not happened. The
commit that carries these fixes is listed in the repository history, and
`swift test` prints the rate on every run. The expected effect of each fix is in
the table above; the custom-qualified control is the one disagreement these
changes deliberately do not address.

### The disagreement left in place

`Custom.Button { ... } label: { ... }` is not a SwiftUI control, and both
implementations agree the image inside it has to be named. The tree reaches that
answer by failing to match the call against the list of control names and
climbing past it, where the Python rule matches the spelling `Custom.Button`
against the same list and likewise climbs. The two agree on the reported line, so
this is recorded here as a difference in how the answer is arrived at rather than
a difference in the answer; if the next CI run still reports it as a
disagreement, it is a real one and belongs in the ADR as a gap in the tree's
modelling of a custom view that happens to be named like a control.

### Where the two are expected to differ

- **A modifier written after the closing `#endif`.** The Python rule stops at the
  matching `#endif`; this spike follows one conditional block and then stops. A
  chain continued past the block is not seen as the same expression's chain here.
- **A report's path.** The Python lint prints the path it was given; this one
  prints the path of the file as found, so the same finding carries a different
  prefix. The corpus test compares path, line and rule rather than the printed
  line, so this is not counted as a disagreement.

### Where the tree is simpler

- The label closure of a control is a node, so "is this image inside the label of
  a control" is a walk up the parents rather than a bracket-matching scan with
  three spellings of the same thing (`Button { } label: { }`,
  `Button(action: {}, label: { })`, `Button(action: {}) { }`).
- The arguments of a font call are a list of labelled expressions, so reading the
  size is a lookup by label rather than a search for `size:` at bracket depth.
- Comments and string literals are nodes, so they are never inspected by
  construction, and a `lint-allow` directive is read from real trivia.

### Where the regex scan is simpler

- No toolchain. The Python lint runs anywhere Python does, on any platform, in
  seconds, with no dependency to resolve and no compiler in the loop. The spike
  needs macOS and a multi-minute first build.
- The Python rules already encode the awkward cases in one place. The spike has to
  re-derive each of them from the tree's shape, which is where the differences
  above come from.

## Build time

The package depends on swift-syntax, so the first `swift build` compiles the
parser, which takes minutes on a macOS runner; `swift test` and later builds are
seconds. The CI job caches the SwiftPM build directory keyed on the package
manifest, so only the first run pays. The wall-clock figure for a cold build is
not yet recorded: the run that reported the agreement above did not report its
timings, so it is left out rather than guessed.
