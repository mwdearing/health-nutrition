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

**Status: awaiting the first macOS CI run.** The numbers below are filled in from
the output of `swift test`, which prints the agreement rate and lists every case
that disagrees. Until that run has happened, this section records what the two
implementations are expected to differ on and why, and the table of measured
agreement is empty.

The case count, which `swift test` reports against the corpus, is 55.

| Rule | Cases | Agreeing | Known disagreements |
| --- | --- | --- | --- |
| `unlabeled-image` | 20 reporting, plus the clean cases | _pending_ | see below |
| `fixed-font-size` | 16 reporting, plus the clean cases | _pending_ | see below |
| Both | 55 cases in total | _pending_ | |

### Where the two are expected to differ

These are the places where the tree and the regex scan cannot be equivalent. Each
is a case the corpus contains, so the measured agreement will show them.

- **A modifier written after the closing `#endif`.** The Python rule stops at the
  matching `#endif`; this spike follows one conditional block and then stops. A
  chain continued past the block is not seen as the same expression's chain here.
- **A nested `content:` argument.** A `content:` label belonging to another call
  inside the control's own argument list is left to the tree, which knows which
  call owns it. The Python rule has to check bracket depth to reach the same
  answer, and the two agree on the corpus case for it.
- **A file name in the report.** The Python lint prints the path it was given;
  this one prints the path of the file as found, so the two lines differ textually
  on a clean tree with no findings, and on a finding the same file carries a
  different prefix. The corpus test compares path, line and rule, not the printed
  line.

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

The first `swift build` compiles swift-syntax, the parser, which is a few
minutes on a macOS runner. Once the package is built, `swift build` and
`swift test` are seconds. The CI job caches the SwiftPM build directory keyed on
the package manifest, so only the first run pays.
