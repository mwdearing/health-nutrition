# view-lint

A SwiftSyntax version of two rules of `scripts/lint_swift_sources.py`: `unlabeled-image` and `fixed-font-size`. It reads
a real Swift syntax tree, so `#if` blocks, nested closures and call chains are structure rather than text to guess at
(#68). The Python lint stays the gate; this tool is an experiment that has to match it before anything depends on it.

## Build and run

```sh
cd tools/view-lint
swift build -c release            # about 6 minutes the first time (it builds swift-syntax), seconds after
.build/release/ViewLint ../../ios/NutritionCore/Sources/NutritionUI ../../ios/HealthNutrition/Sources
```

It prints `path:line: rule: message` for each finding and exits 1 when there is one. `VIEW_LINT_DUMP=1` also prints
each file's syntax tree. It needs a Swift 6 toolchain and no Xcode, so it builds on Linux.

The tool checks every file it is given. Path scoping (which folders the rules apply to) and the `// lint-allow:`
comment are the Python script's job and are not repeated here.

## Comparing it with the text lint

`scripts/tests/view_lint_diff.py` is a pytest plugin that runs the text lint's own tests and, on every tree a test
builds, also runs this tool, then writes `AGREE` or `DIFFER` per test:

```sh
python3 -m venv .venv && .venv/bin/pip install pytest
PYTHONPATH=scripts/tests VIEW_LINT_BIN=$PWD/tools/view-lint/.build/release/ViewLint \
    .venv/bin/python -m pytest -p view_lint_diff scripts/tests/test_lint_swift_sources.py -q
cat view-lint-diff.txt
```

## Result so far

On the 89 trees the text lint's tests build, the two agree on 79. The 10 that differ:

- 6 are scoping or `lint-allow` (the Python script applies both, this tool does not) or run the Python lint over the
  app's widget folders, which it does not scope in.
- 4 are tests written in Swift that does not parse: a view statement inside a postfix `#if` arm
  (`Text(...)` after `.accessibilityHidden(true)`), and `Custom.Button(action: {}) label: { ... }`, where `label:` cannot
  follow the argument list. The tool reads what the parser makes of them, which is not what the tests meant.
- None is a difference on valid Swift. The shapes reviewers raised agree too: a label whose only `Text` is inside an
  `#if` without `#else` is a finding, while an `#if ... #else` whose arms each hold a `Text` is not.

On the real tree (`ios/NutritionCore/Sources/NutritionUI` and `ios/HealthNutrition/Sources`) both report nothing.
The tool checks every file it is given, so run over the whole `ios/HealthNutrition` root it also reports three images in
the Gauge labels of `Widgets/TodayWidget.swift` and `WatchWidgets/WatchTodayWidget.swift`: the Python lint does not
scope those folders in (`is_view_scope`). That is the same scoping difference as above, and a decision for whoever
makes the tool a check.

A path that does not exist, or a file that cannot be read, exits 2 with a message, as the Python lint does.
