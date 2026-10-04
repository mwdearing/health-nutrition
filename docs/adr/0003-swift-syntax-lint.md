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

## Cost

| | Python (today) | SwiftSyntax spike | SwiftSyntax for all |
| --- | --- | --- | --- |
| Toolchain | Python 3, nothing else | macOS, Swift 6, swift-syntax 600.0.0 | the same |
| First build | seconds | a few minutes (swift-syntax is a large dependency) | the same |
| Steady-state run | seconds | seconds once built | seconds once built |
| CI minutes | existing ubuntu job | one advisory macOS job, `continue-on-error` | the swift-lint job moves to macOS and becomes blocking |
| Where findings surface | every PR, blocking | the same job, non-blocking, plus the package README | blocking, on macOS |

The macOS job is deliberately advisory. It builds the package, runs its corpus
test and runs the tool over `ios/NutritionCore` and `ios/HealthNutrition`, and it
does not gate anything, because a spike that blocks a pull request stops the
experiments that would tell us whether to adopt it.

The honest cost of option 2 is duplicated logic: for as long as both
implementations exist, every change to one rule's meaning has to be made twice, and
the corpus test is what keeps them honest. That is only acceptable while the spike
is a measurement.

## What the spike measures

`scripts/export_lint_corpus.py` exports the cases of
`scripts/tests/test_lint_swift_sources.py` that exercise these two rules, with the
findings the Python lint reports for each, into
`tools/swift-syntax-lint/Tests/corpus.json`. The exporter checks every case
against the lint that wrote it, so the corpus cannot drift. The package's test
target then runs every case through the Swift rules and prints the agreement rate
and each disagreement. `tools/swift-syntax-lint/README.md` records the result.

The differences the spike is expected to show, from reading the two
implementations rather than from measurement:

- The tree reads a label closure, a `Text` call and an argument label as nodes, so
  the control-label rules and the font-size rules are much shorter than their
  bracket-scanning counterparts. That is the case for the tree.
- The tree follows one conditional block and stops, where the Python rule follows
  a chain past the matching `#endif`. The tree is *less* thorough there, because
  modelling a postfix chain across a conditional is what the Python rule was
  written to do and the tree does not hand it over for free.
- The Python rule reaches a nested `content:` by checking bracket depth; the tree
  knows which call owns the label. Here the tree is more correct by construction.

So the honest reading is: the tree makes these two rules shorter and structurally
clearer, and does not automatically make them more correct. Whether the remaining
gaps are worth closing is the question this ADR leaves open.

## Recommendation

Adopt option 2 as a measurement and decide again once the numbers are in:

1. If the agreement rate is high and the disagreements are only the documented
   ones, the case for moving these two rules is that the tree is materially
   simpler. That has to be weighed against the duplicated-logic cost, which is
   only justified while the Python version can be deleted.
2. If the disagreements are wide, the tree is not cheaper in practice: it needs a
   toolchain, a macOS runner and hand-written modelling of every awkward case the
   Python rules already encode. Keep option 1 and stop.

Either way the decision needs the measured agreement first, so this ADR stays
Proposed until the macOS job has reported. The recommendation on offer is not to
adopt anything yet: to read the README's agreement table, and to delete this
spike if it does not change the answer.
