"""Differential run: the text lint's own tests, with the SwiftSyntax tool run over the same trees.

Usage (from the repo root):
    VIEW_LINT_BIN=tools/view-lint/.build/release/ViewLint python3 -m pytest -p scripts.tests.view_lint_diff \
        scripts/tests/test_lint_swift_sources.py -q -p no:cacheprovider

Every call of the tests' `run(root)` also runs the tool over `root`. The two rules both tools implement are compared
as (file name, line, rule) sets, and each disagreement is appended to $VIEW_LINT_DIFF_OUT (default view-lint-diff.txt).
The tests themselves still judge the text lint, so they pass or fail as they always do.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

RULES = {"unlabeled-image", "fixed-font-size"}


def _parse(output: str) -> set[tuple[str, int, str]]:
    found = set()
    for line in output.splitlines():
        parts = line.split(":", 3)
        if len(parts) < 4:
            continue
        rule = parts[2].strip()
        if rule in RULES:
            found.add((parts[0], int(parts[1]), rule))
    return found


def pytest_sessionstart(session) -> None:
    """Start each run with an empty log, so a rerun does not stack on the last one."""
    if os.environ.get("VIEW_LINT_BIN"):
        Path(os.environ.get("VIEW_LINT_DIFF_OUT", "view-lint-diff.txt")).unlink(missing_ok=True)


@pytest.fixture(autouse=True)
def _compare(request, monkeypatch):
    binary = os.environ.get("VIEW_LINT_BIN")
    if not binary:
        yield
        return
    import test_lint_swift_sources as module

    original = module.run
    out = Path(os.environ.get("VIEW_LINT_DIFF_OUT", "view-lint-diff.txt"))

    def wrapped(root: Path):
        result = original(root)
        tool = subprocess.run([binary, str(root)], capture_output=True, text=True, check=False)
        text, swift = _parse(result.stdout), _parse(tool.stdout)
        if tool.returncode not in (0, 1) or (tool.returncode == 1 and not swift):
            # (Exit 1 means "found something", so an exit 1 with nothing parsed is a failed run, not a clean one.)
            # A crash or a usage error is never an agreement, whatever it printed.
            swift = swift | {("tool-failed", tool.returncode, tool.stderr.strip()[:80])}
        # Paths differ by tree (the tmp_path of each run), so findings are compared by their path under the tree. The
        # text lint also reads the app target beside the package root, so the base is two levels up from the root.
        base = root.parent.parent

        def relative(finding):
            path, number, rule = finding
            try:
                return (Path(path).relative_to(base).as_posix(), number, rule)
            except ValueError:
                return finding

        text = {relative(finding) for finding in text}
        swift = {relative(finding) for finding in swift}
        with out.open("a", encoding="utf-8") as handle:
            status = "AGREE" if text == swift else "DIFFER"
            handle.write(f"{status} {request.node.name}\n")
            if text != swift:
                handle.write(f"  text-only : {sorted(text - swift)}\n  swift-only: {sorted(swift - text)}\n")
        return result

    monkeypatch.setattr(module, "run", wrapped)
    yield
