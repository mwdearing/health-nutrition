# ADR 0003: Whether the Swift accessibility lint rules move to SwiftSyntax

Status: Proposed

## Context

`scripts/lint_swift_sources.py` enforces six rules over the Swift sources. Two of
them, `unlabeled-image` and `fixed-font-size`, are the ones that need to know what
the code *means* rather than what it spells:

- Every image in a view has to be named for VoiceOver, either by its own modifier
  chain, by the control whose label closure it sits in, by the `Text` of that
  label, or by the title of a `Label`. A name only counts when every configuration
  that compiles the image also compiles a name.
- No font may be pinned to a literal point size, with the font API identified by
  whether the call is spelled on `Font` or written inside `.font(...)`.

Both rules are currently regular expressions over a masked copy of the source.
The masking blanks comments and string literals while keeping offsets, and then
the rules recover structure by scanning brackets: which closure a construct sits
in, which call a closure labels, which `#if` arms a modifier is written in, and at
what bracket depth a `size:` label really belongs to. That recovery is where the
bulk of the code lives. `unlabeled_images` is the longest function in the script,
and the accompanying machinery (`_label_window`, `_control_of`, `_conditional_chain_end`,
`_call_expression_end` and a dozen helpers) exists only to answer questions a
parser already answers.

The two rules have also grown: conditional-compilation handling and nested
modifiers arrived as separate fixes, each adding cases to a suite that is now
1600 lines of synthetic Swift trees. Nothing suggests the growth has stopped.

A Swift package built on `swift-syntax` can parse each file, walk it with a
`SyntaxVisitor` and answer all of those questions directly. The question is
whether that is worth doing, and how far to take it.

## Options

### 1. Keep the Python lint

Status quo. No new toolchain, no new CI job, no macOS minutes. The cost is the
bracket-scanning machinery, which stays as long as the rules do and which every
new case has to be argued against.

### 2. SwiftSyntax for these two rules, Python for the rest

The spike as built. `tools/swift-syntax-lint/` reimplements `unlabeled-image` and
`fixed-font-size` on a syntax tree and runs over the same snippets as the Python
rules, so the two can be compared case by case. The other four rules stay in
Python, because none of them needs to know what the code means: `colour-literal`,
`fixed-font` and `binary-float` are spellings, and `forbidden-import` is a
spelling at the top of a line.

This is the option the spike measures. Its cost is real and is stated below.

### 3. SwiftSyntax for all six rules

The same package grows the other four rules, and the Python lint is deleted. The
benefit is one lint, one toolchain, one place the rules live. The cost is that
every Swift change now needs a macOS runner with a resolved toolchain and a
multi-minute first build, where today it needs Python and nothing else, and that a
lint failure would block a pull request on infrastructure rather than on the code.

## What the spike measured

`scripts/export_lint_corpus.py` exports the cases of
`scripts/tests/test_lint_swift_sources.py` that exercise these two rules, with the
findings the Python lint reports for each, into
`tools/swift-syntax-lint/Tests/corpus.json`. The exporter checks every case
against the lint that wrote it, so the corpus cannot drift. The package's test
target then runs every case through the Swift rules and prints the agreement rate
and each disagreement. `tools/swift-syntax-lint/README.md` records the result.

The corpus is 55 cases: 30 that expect at least one finding and 25 that expect
none. The first macOS run reported **46 of 55 agreeing, 83%**. Every
disagreement it named is about an image, so `fixed-font-size` agreed everywhere it
was exercised. The nine
disagreements were:

| Disagreement | Cases | Cause |
| --- | --- | --- |
| The app target was not linted from a run over the package root | 2 | The expansion into the sibling target was left to the caller |
| Decorative and `.accessibilityHidden(true)` images | 2 | The chain walk stopped at the member access and never read the call's arguments |
| A label present in every `#if` branch | 3 | An arm written in expression position holds a postfix expression, not a statement list |
| A `Text` hidden from accessibility still named its control | 2 | The same chain-walk cause, on the text's own modifier |
| A custom-qualified control, `Custom.Button` | 1 | Left unfixed, see below |

Every one of those is a bug in the spike rather than a difference in the rules,
and all but the last were fixed in the following commit. That the four distinct
causes were all in the *tree traversal* rather than in the rule logic is itself
the first result: the exemptions were right, and the tree was being asked the
wrong question in four different ways.

The one left in place is `Custom.Button { ... } label: { ... }`, which is not a
SwiftUI control. The tree reaches the right answer by failing to match the call
against the list of control names and climbing past it; the Python rule reaches
it by matching the dotted spelling against the same list. If the next CI run still
reports a disagreement there, it is a real difference in how the two recognise a
custom view named like a control, and it belongs in this ADR as a gap.

## Cost, measured

| | Python (today) | SwiftSyntax spike | SwiftSyntax for all |
| --- | --- | --- | --- |
| Toolchain | Python 3, nothing else | macOS, Swift 6, swift-syntax 600.0.0 | the same |
| First build | seconds | minutes: swift-syntax is a large dependency | the same |
| Steady-state run | seconds | seconds once built | seconds once built |
| CI | existing blocking ubuntu job | one advisory macOS job, `continue-on-error`, cache keyed on the manifest | the swift-lint job moves to macOS and becomes blocking |
| Minutes added per PR | none | one macOS runner on PRs touching the package | every PR touching Swift |

The macOS job is deliberately advisory. It builds the package, runs its corpus
test and runs the tool over `ios/NutritionCore` and `ios/HealthNutrition`, and it
does not gate anything, because a spike that blocks a pull request stops the
experiments that would tell us whether to adopt it.

The cold-build wall clock is not recorded. The run that produced the 83% did not
report timings, so the table says "minutes" rather than a number, and the next
run should fill it in.

The honest cost of option 2 is duplicated logic: for as long as both
implementations exist, every change to one rule's meaning has to be made twice,
and the corpus test is what keeps them honest. The 9 disagreements that first run
produced are what that duplication costs in practice, and they landed in one
commit against roughly 350 lines of Swift.

## Recommendation

Not yet. The measurement is not complete: the first run agreed on 83%, and eight
of its nine disagreements were spike bugs that are now fixed, so the next run
gives the real figure. Nothing should be adopted on 83%.

What the first run does support, weakly, is that the tree is worth finishing the
measurement on. The rules themselves were right; what was wrong was four
different ways of asking the tree a question, and each was a small local fix in
the traversal rather than a change to what the rule means. If the next run comes
back at or near full agreement, the case for option 2 is that these two rules are
materially shorter and structurally clearer on a tree — which the line counts
already suggest — weighed against the duplicated logic, which is only justified
while the Python version can be deleted. If it comes back with disagreements that
are *not* local fixes, the answer is option 1 and this spike should be deleted.

So: read the next run's agreement table, then decide, and keep this ADR Proposed
until it is decided.
