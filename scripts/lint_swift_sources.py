#!/usr/bin/env python3
"""Lint Swift sources for the health-nutrition app.

Usage:
    python3 scripts/lint_swift_sources.py [ROOT]

ROOT defaults to ``ios/NutritionCore``. Each finding is reported as
``path:line: rule: message``. The script exits 1 when there is at least one
finding, 0 when the tree is clean and 2 on a usage error.

Rules
-----
colour-literal
    In ``Sources/NutritionUI/**``: no ``Color(red:``, ``UIColor(red:``,
    ``NSColor(red:``, ``Color(hex:`` or ``#RRGGBB`` literals. ``TokenColors.swift``
    is the single allowed place where design tokens become colours.
fixed-font
    In ``Sources/NutritionUI/**``: no ``.font(.system(size:`` or
    ``Font.system(size:``. Text must use Dynamic Type styles.
forbidden-import
    In ``Sources/NutritionUI/**`` and ``Sources/NutritionJournal/**``: no
    ``import HealthKit``, ``import Network`` or ``URLSession``.
binary-float
    In ``Sources/NutritionDomain/**`` and ``Sources/NutritionJournal/**``: no
    ``Double`` or ``Float``. Quantities use ``Decimal``.

``//`` comments, ``/* */`` comments and the contents of string literals
(including multi-line ``\"\"\"`` literals) are never inspected.

Allowing a finding
------------------
A line whose trailing comment is ``// lint-allow: <rule>`` is skipped for that
rule, e.g.::

    let tint = Color(red: 1, green: 0, blue: 0) // lint-allow: colour-literal

Several rules can be listed, separated by spaces or commas. The exemption
applies only to the line it appears on. No Swift source in the repository uses
this mechanism today.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path("ios") / "NutritionCore"

SKIPPED_DIRS = {".build", ".git", "DerivedData", "node_modules"}

HEX_COLOUR = re.compile(r"#(?:[0-9A-Fa-f]{6})(?![0-9A-Fa-f])")
COLOUR_CALL = re.compile(r"\b(?:Color|UIColor|NSColor)\((?:red|hex):")
FIXED_FONT = re.compile(r"\bFont\s*\.\s*system\s*\(\s*size:|\.font\s*\(\s*\.system\s*\(\s*size:")
FORBIDDEN_IMPORT = re.compile(r"^\s*import\s+(?:HealthKit|Network)\b")
URL_SESSION = re.compile(r"\bURLSession\b")
BINARY_FLOAT = re.compile(r"\b(?:Double|Float)\b")

ALLOW_COMMENT = re.compile(r"//\s*lint-allow:\s*(?P<rules>[A-Za-z0-9_,\s-]+?)\s*$")

RULES = (
    "colour-literal",
    "fixed-font",
    "forbidden-import",
    "binary-float",
)

MESSAGES = {
    "colour-literal": "hard-coded colour; use the design tokens via TokenColors",
    "fixed-font": "fixed font size; use a Dynamic Type text style",
    "forbidden-import": "forbidden framework use in this layer",
    "binary-float": "binary floating point; use Decimal",
}


def mask_code(source: str) -> str:
    """Blank out comments and string literals, keeping lines and offsets.

    Everything that is not real code is replaced by spaces so that line
    numbers and column positions stay intact for the regexes.
    """
    out: list[str] = []
    i = 0
    n = len(source)
    # 0 = code, 1 = line comment, 2 = block comment, 3 = string, 4 = multiline string
    state = 0
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if state == 0:
            if ch == "/" and nxt == "/":
                state = 1
                out.append("  ")
                i += 2
                continue
            if ch == "/" and nxt == "*":
                state = 2
                out.append("  ")
                i += 2
                continue
            if source.startswith('"""', i):
                state = 4
                out.append("   ")
                i += 3
                continue
            if ch == '"':
                state = 3
                out.append(" ")
                i += 1
                continue
            out.append(ch)
            i += 1
            continue
        if state == 1:
            if ch == "\n":
                state = 0
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue
        if state == 2:
            if ch == "*" and nxt == "/":
                state = 0
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        # inside a string literal
        if state == 3:
            if ch == "\\" and nxt:
                out.append("  " if nxt != "\n" else " \n")
                i += 2
                continue
            if ch == '"':
                state = 0
                out.append(" ")
                i += 1
                continue
            if ch == "\n":  # unterminated literal; do not leak into the next line
                state = 0
                out.append("\n")
                i += 1
                continue
            out.append(" ")
            i += 1
            continue
        # state == 4, multi-line string literal
        if source.startswith('"""', i):
            state = 0
            out.append("   ")
            i += 3
            continue
        out.append("\n" if ch == "\n" else " ")
        i += 1
    return "".join(out)


def allowed_rules(line: str) -> set[str]:
    """Rule names allowed on this line by a trailing ``lint-allow`` comment."""
    match = ALLOW_COMMENT.search(line.rstrip())
    if not match:
        return set()
    names = {part.strip() for part in re.split(r"[,\s]+", match.group("rules")) if part.strip()}
    return {name.replace("_", "-") for name in names}


def applies(rel: str, prefixes: tuple[str, ...]) -> bool:
    posix = rel.replace("\\", "/")
    return any(posix.startswith(prefix) for prefix in prefixes)


def check_file(path: Path, root: Path) -> list[tuple[int, str, str]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    raw_lines = text.splitlines()
    code_lines = mask_code(text).splitlines()
    rel = path.relative_to(root).as_posix()
    base = path.name

    is_ui = applies(rel, ("Sources/NutritionUI/",))
    is_net_scoped = applies(rel, ("Sources/NutritionUI/", "Sources/NutritionJournal/"))
    is_float_scoped = applies(rel, ("Sources/NutritionDomain/", "Sources/NutritionJournal/"))
    colour_exempt = base == "TokenColors.swift"

    findings: list[tuple[int, str, str]] = []
    for number, (raw, code) in enumerate(zip(raw_lines, code_lines), start=1):
        allow = allowed_rules(raw)
        if not code.strip():
            continue

        def report(rule: str) -> None:
            if rule in allow:
                return
            findings.append((number, rule, MESSAGES[rule]))

        if is_ui and not colour_exempt:
            if COLOUR_CALL.search(code) or HEX_COLOUR.search(code):
                report("colour-literal")
        if is_ui and FIXED_FONT.search(code):
            report("fixed-font")
        if is_net_scoped and (FORBIDDEN_IMPORT.search(code) or URL_SESSION.search(code)):
            report("forbidden-import")
        if is_float_scoped and BINARY_FLOAT.search(code):
            report("binary-float")
    return findings


def swift_files(root: Path) -> list[Path]:
    files = []
    for path in sorted(root.rglob("*.swift")):
        if any(part in SKIPPED_DIRS for part in path.parts):
            continue
        files.append(path)
    return files


def lint(root: Path) -> list[str]:
    lines: list[str] = []
    for path in swift_files(root):
        for number, rule, message in check_file(path, root):
            lines.append(f"{path}:{number}: {rule}: {message}")
    return lines


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else DEFAULT_ROOT
    if not root.is_dir():
        print(f"error: not a directory: {root}", file=sys.stderr)
        return 2
    findings = lint(root)
    for line in findings:
        print(line)
    if findings:
        print(f"{len(findings)} finding(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))