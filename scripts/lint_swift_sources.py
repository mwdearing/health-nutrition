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
    ``import HealthKit``, ``import Network`` or ``URLSession``. Declaration-kind
    and attributed forms such as ``import class HealthKit.HKHealthStore`` and
    ``@_implementationOnly import Network`` count too.
binary-float
    In ``Sources/NutritionDomain/**`` and ``Sources/NutritionJournal/**``: no
    ``Double`` or ``Float``, and no untyped floating-point literal such as
    ``0.1`` or ``1e-3``, which Swift would infer as ``Double``. Quantities use
    ``Decimal``.

Matching runs over the whole masked source rather than one line at a time, so a
prohibited call wrapped over several lines is still matched. A finding is
reported on the line where the construct starts.

``//`` comments, ``/* */`` comments (including nested ones) and the contents of
string literals are never inspected. Extended literals delimited with hashes are
handled, and the expressions inside ``\\(`` interpolations count as code,
because they are.

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
COLOUR_CALL = re.compile(r"\b(?:Color|UIColor|NSColor)\s*\(\s*(?:red|hex)\s*:")
FIXED_FONT = re.compile(
    r"\bFont\s*\.\s*system\s*\(\s*size\s*:"
    r"|\.font\s*\(\s*\.system\s*\(\s*size\s*:"
)
IMPORT_KINDS = r"(?:class|struct|enum|protocol|typealias|func|var|let|actor|associatedtype|operator|precedencegroup)"
FORBIDDEN_IMPORT = re.compile(
    r"^[ \t]*(?:@[\w.]+(?:\([^()]*\))?[ \t]+)*import[ \t]+"
    rf"(?:{IMPORT_KINDS}[ \t]+)?(?:HealthKit|Network)\b",
    re.MULTILINE,
)
URL_SESSION = re.compile(r"\bURLSession\b")
BINARY_FLOAT_TYPE = re.compile(r"\b(?:Double|Float)\b")
# A floating-point literal without an explicit type: Swift infers Double.
BINARY_FLOAT_LITERAL = re.compile(
    r"(?<![0-9A-Za-z_.])(?:[0-9][0-9_]*\.[0-9][0-9_]*(?:[eE][+-]?[0-9]+)?"
    r"|[0-9][0-9_]*[eE][+-]?[0-9]+)"
    r"(?![0-9A-Za-z_])"
)

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


def _blank(text: str) -> str:
    """Replace every character with a space, keeping newlines and length."""
    return "".join("\n" if ch == "\n" else " " for ch in text)


def _string_start(source: str, i: int) -> tuple[int, bool] | None:
    """Return ``(hashes, multiline)`` if a string literal starts at ``i``.

    Swift extended literals use hash delimiters (``#"raw"#``, ``##'''raw'''##``)
    and may contain unescaped quotes, so the number of opening hashes decides
    what actually closes the literal. ``None`` means no literal starts here.
    """
    ch = source[i]
    hashes = 0
    while i + hashes < len(source) and source[i + hashes] == "#":
        hashes += 1
    if ch == "#" and hashes == 0:
        return None
    j = i + hashes
    if not source.startswith('"', j):
        return None
    if ch != "#" and hashes:
        return None
    return hashes, source.startswith('"""', j)


def _mask_block_comment(source: str, i: int, out: list[str]) -> int:
    """Mask a ``/* ... */`` comment, honouring Swift's nested comments."""
    out.append("  ")
    i += 2
    depth = 1
    n = len(source)
    while i < n and depth:
        if source.startswith("/*", i):
            depth += 1
            out.append("  ")
            i += 2
            continue
        if source.startswith("*/", i):
            depth -= 1
            out.append("  ")
            i += 2
            continue
        out.append("\n" if source[i] == "\n" else " ")
        i += 1
    return i


def _mask_string(source: str, i: int, hashes: int, multiline: bool, out: list[str]) -> int:
    """Mask a string literal; interpolations are real code and stay unmasked."""
    n = len(source)
    opening = 3 if multiline else 1
    i += hashes
    out.append(_blank(source[i - hashes:i + opening]))
    i += opening
    terminator = '"' + ("#" * hashes)
    closer = '"""' + ("#" * hashes) if multiline else terminator
    while i < n:
        ch = source[i]
        if ch == "\\" and i + 1 < n:
            nxt = source[i + 1]
            if nxt == "(" and not hashes:
                # Interpolation: the expression inside is compiled Swift code.
                out.append("  ")
                i = _mask_code(source, i + 2, out, stop_on_close_paren=True)
                if i < n and source[i] == ")":
                    out.append(")")
                    i += 1
                continue
            if nxt == "\n":
                out.append(" \n")
                i += 2
                continue
            out.append("  ")
            i += 2
            continue
        if source.startswith(closer, i):
            out.append(_blank(closer))
            i += len(closer)
            return i
        if not multiline and ch == "\n":
            # Unterminated literal: do not leak into the next line.
            out.append("\n")
            return i + 1
        out.append("\n" if ch == "\n" else " ")
        i += 1
    return i


def _mask_code(source: str, i: int, out: list[str], stop_on_close_paren: bool = False) -> int:
    """Mask Swift code from ``i``, returning the index where it stopped.

    When ``stop_on_close_paren`` is set the scan ends at the parenthesis that
    closes the string interpolation it was called from.
    """
    n = len(source)
    depth = 0
    while i < n:
        ch = source[i]
        if stop_on_close_paren:
            if ch == ")":
                if depth == 0:
                    return i
                depth -= 1
            elif ch == "(":
                depth += 1
        if ch == "/" and source.startswith("//", i):
            j = i
            while j < n and source[j] != "\n":
                j += 1
            out.append(_blank(source[i:j]))
            i = j
            continue
        if ch == "/" and source.startswith("/*", i):
            i = _mask_block_comment(source, i, out)
            continue
        if ch == '"' or ch == "#":
            start = _string_start(source, i)
            if start is not None:
                hashes, multiline = start
                i = _mask_string(source, i, hashes, multiline, out)
                continue
        out.append(ch)
        i += 1
    return i


def mask_code(source: str) -> str:
    """Blank out comments and string literals, keeping lines and offsets.

    Everything that is not real code is replaced by spaces so that line
    numbers and column positions stay intact for the regexes. String
    interpolations keep their expression, because that expression is code.
    """
    out: list[str] = []
    _mask_code(source, 0, out)
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
    masked = mask_code(text)
    raw_lines = text.splitlines()
    rel = path.relative_to(root).as_posix()
    base = path.name

    is_ui = applies(rel, ("Sources/NutritionUI/",))
    is_net_scoped = applies(rel, ("Sources/NutritionUI/", "Sources/NutritionJournal/"))
    is_float_scoped = applies(rel, ("Sources/NutritionDomain/", "Sources/NutritionJournal/"))
    colour_exempt = base == "TokenColors.swift"

    patterns: list[tuple[str, re.Pattern[str]]] = []
    if is_ui and not colour_exempt:
        patterns.append(("colour-literal", HEX_COLOUR))
        patterns.append(("colour-literal", COLOUR_CALL))
    if is_ui:
        patterns.append(("fixed-font", FIXED_FONT))
    if is_net_scoped:
        patterns.append(("forbidden-import", FORBIDDEN_IMPORT))
        patterns.append(("forbidden-import", URL_SESSION))
    if is_float_scoped:
        patterns.append(("binary-float", BINARY_FLOAT_TYPE))
        patterns.append(("binary-float", BINARY_FLOAT_LITERAL))

    allows = [allowed_rules(line) for line in raw_lines]
    # Offsets of the first character of each line, so a match that starts on
    # line 3 is reported on line 3 even when it spans several lines.
    starts: list[int] = []
    offset = 0
    for line in text.splitlines(keepends=True):
        starts.append(offset)
        offset += len(line)

    def line_of(position: int) -> int:
        low, high = 0, len(starts) - 1
        while low < high:
            mid = (low + high + 1) // 2
            if starts[mid] <= position:
                low = mid
            else:
                high = mid - 1
        return low + 1

    found: dict[tuple[int, str], None] = {}
    for rule, pattern in patterns:
        for match in pattern.finditer(masked):
            number = line_of(match.start())
            if number - 1 >= len(allows) or rule in allows[number - 1]:
                continue
            found[(number, rule)] = None

    order = {name: index for index, name in enumerate(RULES)}
    return [(number, rule, MESSAGES[rule]) for number, rule in sorted(found, key=lambda k: (k[0], order[k[1]]))]


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