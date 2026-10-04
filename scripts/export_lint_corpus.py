#!/usr/bin/env python3
"""Export the SwiftSyntax lint corpus from the Python lint's own tests.

The spike in ``tools/swift-syntax-lint`` reimplements two rules of
``scripts/lint_swift_sources.py`` -- ``unlabeled-image`` and ``fixed-font-size``
-- on a SwiftSyntax tree. To say whether the reimplementation agrees with the
Python one, both have to be run over the same snippets. This script builds that
shared corpus: it reads the test cases out of
``scripts/tests/test_lint_swift_sources.py``, keeps the ones that exercise those
two rules, and writes them with the findings the Python lint reports to
``tools/swift-syntax-lint/Tests/corpus.json``.

Usage:
    python3 scripts/export_lint_corpus.py [--check]

The corpus is read by the Swift package's test target, which runs the spike's
own rules over every case and reports where the two implementations agree. With
``--check`` the script only compares what it would write against the committed
file and exits 1 when they differ, which is how CI keeps the two in step.

Expected findings are read from the test cases themselves rather than from the
lint's output alone, and the lint is then run over the same snippets, so a
mismatch between what a test claims and what the lint reports fails the export
instead of quietly recording the wrong expectation.
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lint_swift_sources import MESSAGES  # noqa: E402

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
TEST_FILE = REPOSITORY_ROOT / "scripts" / "tests" / "test_lint_swift_sources.py"
LINT_SCRIPT = REPOSITORY_ROOT / "scripts" / "lint_swift_sources.py"
CORPUS_FILE = REPOSITORY_ROOT / "tools" / "swift-syntax-lint" / "Tests" / "corpus.json"

# The two rules the spike reimplements. The corpus holds those and nothing else,
# so a finding from another rule is filtered out rather than exported.
CORPUS_RULES = ("unlabeled-image", "fixed-font-size")

# The directory constants the test module writes its trees under. They are
# resolved to real paths so an f-string key such as ``f"{UI}/IconButton.swift"``
# reads as the file it is.
MODULE_DIRS = {
    "UI": "Sources/NutritionUI",
    "DOMAIN": "Sources/NutritionDomain",
    "JOURNAL": "Sources/NutritionJournal",
    "PROVIDERS": "Sources/NutritionProviders",
}

# The construct either rule looks for. A case whose snippets contain one of them
# is about these two rules even when it expects no finding at all, which is how
# the scope and the exemption cases are kept.
CONSTRUCT = re.compile(r"\bImage\s*\(|\bFont\s*\.|\.\s*(?:system|custom|pointSize)\s*\(")

# The root a run is started from. Both targets sit beside each other under
# `ios/`, so a run over the package root covers the app target too.
PACKAGE_ROOT = "NutritionCore"
APP_ROOT = "HealthNutrition"
# The directory the two roots are found in, which the corpus paths are relative
# to so a case can be written out and linted without knowing the temp directory.
CONTAINER = "ios"


class ExportError(Exception):
    """A test case the exporter cannot read."""


def _string(node: ast.AST) -> str | None:
    """The value of a string literal, an f-string of known names, or ``None``."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        parts = []
        for value in node.values:
            if isinstance(value, ast.FormattedValue):
                name = value.value
                if not isinstance(name, ast.Name) or name.id not in MODULE_DIRS:
                    return None
                parts.append(MODULE_DIRS[name.id])
            elif isinstance(value, ast.Constant) and isinstance(value.value, str):
                parts.append(value.value)
            else:
                return None
        return "".join(parts)
    return None


def _path(node: ast.AST, names: dict[str, tuple[str, ...]]) -> tuple[str, ...] | None:
    """The path an expression names, as its components, or ``None``."""
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
        left = _path(node.left, names)
        right = _path(node.right, names)
        if left is None or right is None:
            return None
        return (*left, *right)
    text = _string(node)
    if text is not None:
        return (text,)
    if isinstance(node, ast.Name):
        return names.get(node.id)
    return None


def _relative(parts: tuple[str, ...]) -> tuple[str, ...]:
    """A path written under the temp directory, relative to its ``ios`` folder."""
    if parts and parts[0] == CONTAINER:
        parts = parts[1:]
    return parts


def _call_name(node: ast.AST) -> str | None:
    """The bare name of the function or method a call expression invokes."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return None


class Case:
    """One test case, read as a tree of files and the findings it expects."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.files: dict[tuple[str, ...], str] = {}
        self.root: str = PACKAGE_ROOT
        self.expected: list[tuple[int, str, str]] | None = None

    @property
    def mentions_corpus_rule(self) -> bool:
        """Whether the case states an expectation about either corpus rule."""
        return any(rule in CORPUS_RULES for _, _, rule in self.expected or ())

    @property
    def builds_a_construct(self) -> bool:
        """Whether the snippets contain something either corpus rule looks at."""
        return any(CONSTRUCT.search(source) for source in self.files.values())

    def path_of(self, file_name: str) -> tuple[str, ...]:
        """The corpus path of the one file of the case with this base name."""
        matches = [parts for parts in self.files if parts[-1] == file_name]
        if len(matches) != 1:
            raise ExportError(f"{self.name}: file name {file_name} is not unique in the case")
        return matches[0]

    def as_json(self) -> dict[str, object]:
        """The corpus entry: paths relative to ``ios/``, lines and rules."""
        expected = sorted(
            (line, "/".join(self.path_of(name)), rule)
            for line, name, rule in self.expected or ()
            if rule in CORPUS_RULES
        )
        return {
            "name": self.name,
            "lintRoot": self.root,
            "files": [
                {"path": "/".join(parts), "source": source}
                for parts, source in sorted(self.files.items())
            ],
            "expected": [
                {"path": path, "line": line, "rule": rule} for line, path, rule in expected
            ],
        }


def _expected_tuples(node: ast.AST, rule_filter: str | None) -> list[tuple[int, str, str]]:
    """The ``(line, file, rule)`` triples one expectation asserts."""
    triples = []
    for element in node.elts:
        if not isinstance(element, ast.Tuple) or len(element.elts) != 3:
            raise ExportError(f"unexpected expectation entry: {ast.dump(element)}")
        _, line, rule = element.elts
        if rule_filter is not None and _string(rule) != rule_filter:
            continue
        number = line.value if isinstance(line, ast.Constant) else None
        name = _string(element.elts[0])
        if not isinstance(number, int) or name is None:
            raise ExportError(f"unexpected expectation entry: {ast.dump(element)}")
        triples.append((number, name, _string(rule) or ""))
    return triples


def _read_expectation(test: ast.FunctionDef) -> list[tuple[int, str, str]]:
    """The findings a test case expects, as ``(line, file name, rule)`` triples.

    Three assertion shapes are read: the whole list of findings, a list filtered
    to one rule, and a clean run. A clean run is stated either as an empty
    `stdout` or as a zero exit code, and both mean the same thing here. Anything
    else raises, so a case is never exported with an expectation that was only
    half read.
    """
    expected: list[tuple[int, str, str]] = []
    seen = False
    for node in ast.walk(test):
        if not isinstance(node, ast.Assert):
            continue
        test_expr = node.test
        if not isinstance(test_expr, ast.Compare) or len(test_expr.ops) != 1:
            continue
        if not isinstance(test_expr.ops[0], ast.Eq):
            continue
        left, right = test_expr.left, test_expr.comparators[0]
        if isinstance(left, ast.Call) and _call_name(left.func) == "findings":
            expected.extend(_expected_tuples(right, None))
            seen = True
            continue
        # `[f for f in findings(result) if f[2] == "<rule>"] == [...]`
        if isinstance(left, ast.ListComp) and isinstance(left.elt, ast.Name):
            rule_filter = _rule_filter(left)
            if rule_filter is not None and isinstance(right, (ast.List, ast.Tuple)):
                expected.extend(_expected_tuples(right, rule_filter))
                seen = True
                continue
        # `result.stdout == ""` and `result.returncode == 0` both say the run
        # found nothing at all, which is a case that expects no finding.
        if (
            isinstance(left, ast.Attribute)
            and left.attr in {"stdout", "returncode"}
            and isinstance(right, ast.Constant)
            and right.value in ("", 0)
        ):
            seen = True
            continue
    if not seen:
        raise ExportError(f"no readable expectation in {test.name}")
    return expected


def _rule_filter(comprehension: ast.ListComp) -> str | None:
    """The rule name a ``findings`` list comprehension filters on."""
    for condition in comprehension.generators[0].ifs if comprehension.generators else []:
        test = condition
        if (
            isinstance(test, ast.Compare)
            and isinstance(test.left, ast.Subscript)
            and isinstance(test.left.slice, ast.Constant)
            and test.left.slice.value == 2
        ):
            return _string(test.comparators[0])
    return None


def _read_case(test: ast.FunctionDef) -> Case:
    """Read one test function as a tree of files and the run over it."""
    case = Case(test.name)
    # The tests build their trees under a temporary directory, and the two
    # targets sit in an `ios` folder inside it, which corpus paths are relative
    # to so a case can be written out again without knowing the temporary path.
    names: dict[str, tuple[str, ...]] = {"tmp_path": ()}
    written_roots: list[str] = []
    for statement in test.body:
        if isinstance(statement, ast.Assign) and isinstance(statement.value, ast.Call):
            call = statement.value
            name = _call_name(call.func)
            if name == "write_tree":
                case.files.update(_read_tree(call))
                written_roots.append(PACKAGE_ROOT)
            elif name == "run":
                parts = _path(call.args[0], names)
                if parts is not None:
                    case.root = _lint_root(_relative(parts))
            names[statement.targets[0].id] = _path(statement.value, names) or ()
        elif isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call):
            call = statement.value
            name = _call_name(call.func)
            if name == "write_tree":
                case.files.update(_read_tree(call))
                written_roots.append(PACKAGE_ROOT)
            elif name == "write_text":
                _record_write(call, names, case)
        elif isinstance(statement, ast.Assign):
            names[statement.targets[0].id] = _path(statement.value, names) or ()
    if not case.files:
        # The case writes no tree of its own, so it is about the repository or
        # about the script's exit code rather than about a snippet.
        return case
    if not written_roots:
        case.root = APP_ROOT if any(parts[0] == APP_ROOT for parts in case.files) else PACKAGE_ROOT
    try:
        case.expected = _read_expectation(test)
    except ExportError:
        # Left unset: the case is dropped unless something else selects it.
        case.expected = None
    return case


def _read_tree(call: ast.Call) -> dict[tuple[str, ...], str]:
    """The files a ``write_tree(tmp_path, {...})`` call writes."""
    files: dict[tuple[str, ...], str] = {}
    if len(call.args) < 2 or not isinstance(call.args[1], ast.Dict):
        raise ExportError("write_tree without a literal tree")
    for key, value in zip(call.args[1].keys, call.args[1].values, strict=True):
        rel = _string(key) if key is not None else None
        source = _string(value) if value is not None else None
        if rel is None or source is None:
            raise ExportError("write_tree entry that is not a literal string")
        files[(PACKAGE_ROOT, *rel.split("/"))] = source
    return files


def _record_write(call: ast.Call, names: dict[str, tuple[str, ...]], case: Case) -> None:
    """Record a ``(root / "Name.swift").write_text("...")`` call as a file."""
    parts = _path(call.func.value, names)  # type: ignore[attr-defined]
    source = _string(call.args[0]) if call.args else None
    if parts is None or source is None:
        raise ExportError("write_text with a path or body that is not a literal")
    case.files[_relative(parts)] = source


def _lint_root(parts: tuple[str, ...]) -> str:
    """The root a run over these path components lints."""
    if APP_ROOT in parts:
        return APP_ROOT
    return PACKAGE_ROOT


def _linted(source_dir: Path, root: str) -> list[tuple[int, str, str]]:
    """Run the Python lint over ``root`` and read back its corpus findings."""
    result = subprocess.run(
        [sys.executable, str(LINT_SCRIPT), str(source_dir / root)],
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 1):
        raise ExportError(f"lint failed over {root}: {result.stderr.strip()}")
    found = []
    for line in result.stdout.splitlines():
        path, number, rule, _ = line.split(":", 3)
        if rule.strip() in CORPUS_RULES:
            found.append((int(number), Path(path).name, rule.strip()))
    return found


def _actual(case: Case) -> list[tuple[int, str, str]]:
    """The corpus findings the Python lint reports over a case's own snippets."""
    with tempfile.TemporaryDirectory() as temporary:
        source_dir = Path(temporary) / CONTAINER
        by_name: dict[str, list[tuple[str, ...]]] = {}
        for parts, source in case.files.items():
            path = source_dir.joinpath(*parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
            by_name.setdefault(parts[-1], []).append(parts)
        found = []
        for number, name, rule in _linted(source_dir, case.root):
            matches = by_name.get(name, [])
            if len(matches) != 1:
                raise ExportError(f"{case.name}: file name {name} is not unique in the case")
            found.append((number, name, rule))
    return found


def select_cases(tests: list[ast.FunctionDef]) -> list[Case]:
    """The cases the corpus holds: the ones that exercise either corpus rule."""
    cases = []
    for test in tests:
        case = _read_case(test)
        if not case.files or case.expected is None:
            continue
        if case.mentions_corpus_rule or case.builds_a_construct:
            cases.append(case)
    return cases


def checked_findings(case: Case) -> list[tuple[int, str, str]]:
    """The corpus findings of a case, or an error when the lint disagrees.

    The expectation comes from the test case and the finding from the lint, so a
    case whose two do not agree is refused rather than exported with whichever
    of the two happens to be there.
    """
    expected = [
        (line, "/".join(case.path_of(name)), rule)
        for line, name, rule in case.expected or ()
        if rule in CORPUS_RULES
    ]
    actual = [
        (line, "/".join(case.path_of(name)), rule) for line, name, rule in _actual(case)
    ]
    if sorted(expected) != sorted(actual):
        raise ExportError(
            f"{case.name}: the test expects {sorted(expected)} but the lint reports "
            f"{sorted(actual)}"
        )
    return expected


def collect() -> dict[str, object]:
    """Build the corpus, checking every case against the lint that wrote it."""
    module = ast.parse(TEST_FILE.read_text(encoding="utf-8"))
    tests = [
        node
        for node in module.body
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
    ]
    cases = select_cases(tests)
    if not cases:
        raise ExportError("no case exercised either corpus rule")
    for case in cases:
        checked_findings(case)
    return {
        "rules": list(CORPUS_RULES),
        "messages": {rule: MESSAGES[rule] for rule in CORPUS_RULES},
        "cases": [case.as_json() for case in cases],
    }


def render(corpus: dict[str, object]) -> str:
    """The corpus as the exact text written to disk, so a check can compare."""
    return json.dumps(corpus, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="only report whether the committed corpus is up to date",
    )
    args = parser.parse_args(argv)
    try:
        text = render(collect())
    except ExportError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if args.check:
        if not CORPUS_FILE.exists():
            print(f"error: {CORPUS_FILE} does not exist", file=sys.stderr)
            return 1
        if CORPUS_FILE.read_text(encoding="utf-8") != text:
            print(f"error: {CORPUS_FILE} is out of date", file=sys.stderr)
            return 1
        print(f"{CORPUS_FILE.relative_to(REPOSITORY_ROOT)} is up to date.")
        return 0
    CORPUS_FILE.parent.mkdir(parents=True, exist_ok=True)
    CORPUS_FILE.write_text(text, encoding="utf-8")
    cases = len(json.loads(text)["cases"])
    print(f"wrote {cases} case(s) to {CORPUS_FILE.relative_to(REPOSITORY_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
