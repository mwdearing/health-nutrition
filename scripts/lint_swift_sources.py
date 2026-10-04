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
    ``import HealthKit``, ``import Network`` or ``URLSession``. Declaration-kind,
    attributed and access-level forms such as ``import class HealthKit.HKHealthStore``,
    ``@_implementationOnly import Network``, ``private import HealthKit`` and
    ``@preconcurrency public import HealthKit`` count too.
binary-float
    In ``Sources/NutritionDomain/**`` and ``Sources/NutritionJournal/**``: no
    ``Double`` or ``Float``, and no untyped floating-point literal such as
    ``0.1``, ``1e-3`` or the hexadecimal ``0x1.fp2``, which Swift would infer as
    ``Double``. A hex integer such as ``0xFF`` is not a floating-point literal.
    Underscores are allowed in a hex float exponent (``0x1p1_0``) but do not
    make a hex integer a float. Quantities use ``Decimal``.

Matching runs over the whole masked source rather than one line at a time, so a
prohibited call wrapped over several lines is still matched. A finding is
reported on the line where the construct starts.

``//`` comments, ``/* */`` comments (including nested ones), the contents of
string literals and the contents of regex literals are never inspected. Extended
literals delimited with hashes are handled, and the expressions inside ``\\(``
interpolations count as code, because they are. In a hash-delimited literal the
interpolation needs the same number of hashes as the literal, so ``\\#(`` inside
``#"..."#`` is code while a plain ``\\(`` there is text.

A regex literal is ``/.../`` or ``#/.../#`` (and more hashes). To keep division
out of it, a bare ``/`` only opens a regex where an expression may begin, and the
literal has to close on its own line; a postfix ``!`` or ``?`` ends an operand,
so the slash after ``foo!`` or ``a?.b`` divides. Swift's ternary ``?`` is infix and
takes whitespace on both sides, so in ``flag ? /Double/ : /Float/`` the slash does
open a pattern and its text is not code. A hash-delimited literal is unambiguous:
its pattern may start with a space, it may span several lines, and an
interpolation inside it is code, exactly as in an extended string.

Allowing a finding
------------------
A line whose trailing comment is ``// lint-allow: <rule>`` is skipped for that
rule, e.g.::

    let tint = Color(red: 1, green: 0, blue: 0) // lint-allow: colour-literal

Several rules can be listed, separated by spaces or commas. The exemption
applies only to the line it appears on, and only a real comment counts: the same
text inside a multi-line string literal grants nothing. No Swift source in the
repository uses this mechanism today.
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
# An access-level modifier may sit between the attributes and the `import`.
ACCESS_LEVELS = r"(?:private|fileprivate|internal|package|public|open)"
FORBIDDEN_IMPORT = re.compile(
    r"^[ \t]*(?:@[\w.]+(?:\([^()]*\))?[ \t]+)*"
    rf"(?:{ACCESS_LEVELS}[ \t]+)?import[ \t]+"
    rf"(?:{IMPORT_KINDS}[ \t]+)?(?:HealthKit|Network)\b",
    re.MULTILINE,
)
URL_SESSION = re.compile(r"\bURLSession\b")
BINARY_FLOAT_TYPE = re.compile(r"\b(?:Double|Float)\b")
# A floating-point literal without an explicit type: Swift infers Double.
# The hexadecimal form carries a `p` exponent: `0x1.fp2` is a Double, while a
# plain hex integer such as `0xFF` is not a floating-point literal.
BINARY_FLOAT_LITERAL = re.compile(
    r"(?<![0-9A-Za-z_.])(?:[0-9][0-9_]*\.[0-9][0-9_]*(?:[eE][+-]?[0-9]+)?"
    r"|[0-9][0-9_]*[eE][+-]?[0-9]+"
    # The exponent of a hex float may carry underscores too: `0x1.fp2_0`.
    r"|0[xX][0-9A-Fa-f_]*(?:\.[0-9A-Fa-f_]*)?[pP][+-]?[0-9][0-9_]*)"
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


def _mask_block_comment(source: str, i: int, out: list[str], keep_comments: bool = False) -> int:
    """Mask a ``/* ... */`` comment, honouring Swift's nested comments."""
    out.append(source[i:i + 2] if keep_comments else "  ")
    i += 2
    depth = 1
    n = len(source)
    while i < n and depth:
        if source.startswith("/*", i):
            depth += 1
            out.append(source[i:i + 2] if keep_comments else "  ")
            i += 2
            continue
        if source.startswith("*/", i):
            depth -= 1
            out.append(source[i:i + 2] if keep_comments else "  ")
            i += 2
            continue
        out.append("\n" if source[i] == "\n" else " ")
        i += 1
    return i


def _mask_regex(source: str, i: int, hashes: int, out: list[str]) -> int | None:
    """Mask a regex literal opening at ``i``, or return ``None``.

    Swift spells regex literals ``/.../`` with an optional number of hashes in
    front: ``#/.../#`` and ``##/.../##``. Their contents are a pattern, not code,
    except for the interpolations, which are compiled Swift and stay visible.

    To keep division out of it a bare ``/`` only opens a regex where an
    expression may begin, and the literal has to close on its own line. That
    includes a ternary ``?``, which takes whitespace on both sides, while a
    postfix ``!`` or ``?`` ends an operand, so the slash after ``foo!`` or
    ``a?.b`` divides. A hash-delimited literal is unambiguous, so its pattern
    may start with a space and may span several lines: the scan runs to the
    closing delimiter.
    """
    n = len(source)
    start = i + hashes
    if start >= n or source[start] != "/":
        return None
    j = start + 1
    if not hashes and (j >= n or source[j] in " \t\n"):
        # A space or newline after a bare slash reads as division. `#/ Double /#`
        # has no such ambiguity, so hashes allow a leading space.
        return None
    terminator = "/" + "#" * hashes
    # As in an extended string, an interpolation needs the same number of
    # hashes as the literal: `\#(` inside `#/.../#`.
    interpolator = "\\" + "#" * hashes + "("
    parts: list[str] = []
    # Where the pending text to blank starts; interpolated code is written out
    # as it is met, so it is never blanked by a later segment.
    emitted = i
    while j < n:
        ch = source[j]
        if ch == "\n" and not hashes:
            # Only a bare pattern has to close on its own line.
            return None
        if ch == "\\" and j + 1 < n:
            if hashes and source.startswith(interpolator, j):
                parts.append(_blank(source[emitted:j + len(interpolator)]))
                j += len(interpolator)
                j = _mask_code(source, j, parts, stop_on_close_paren=True)
                if j < n and source[j] == ")":
                    parts.append(")")
                    j += 1
                emitted = j
                continue
            parts.append(_blank(source[emitted:j + 2]))
            j += 2
            emitted = j
            continue
        if source.startswith(terminator, j):
            end = j + len(terminator)
            parts.append(_blank(source[emitted:end]))
            out.extend(parts)
            return end
        j += 1
    return None


def _mask_string(
    source: str,
    i: int,
    hashes: int,
    multiline: bool,
    out: list[str],
    keep_comments: bool = False,
) -> int:
    """Mask a string literal; interpolations are real code and stay unmasked."""
    n = len(source)
    opening = 3 if multiline else 1
    i += hashes
    out.append(_blank(source[i - hashes:i + opening]))
    i += opening
    interpolator = "\\" + ("#" * hashes) + "("
    closer = '"""' + ("#" * hashes) if multiline else '"' + ("#" * hashes)
    while i < n:
        ch = source[i]
        if ch == "\\" and i + 1 < n:
            # In a raw string an interpolation needs the same number of hashes
            # as the literal: `\#(` inside `#"..."#`. A plain `\(` there is text.
            # Escape pairs are consumed two characters at a time below, so the
            # backslash reached here always starts a fresh sequence.
            if source.startswith(interpolator, i):
                # Interpolation: the expression inside is compiled Swift code.
                out.append(_blank(interpolator))
                i += len(interpolator)
                i = _mask_code(source, i, out, stop_on_close_paren=True, keep_comments=keep_comments)
                if i < n and source[i] == ")":
                    out.append(")")
                    i += 1
                continue
            nxt = source[i + 1]
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


def _mask_code(
    source: str,
    i: int,
    out: list[str],
    stop_on_close_paren: bool = False,
    keep_comments: bool = False,
) -> int:
    """Mask Swift code from ``i``, returning the index where it stopped.

    When ``stop_on_close_paren`` is set the scan ends at the parenthesis that
    closes the string interpolation it was called from. When ``keep_comments``
    is set, comments are copied through instead of blanked, which is how the
    ``lint-allow`` directives are read from real comments only.
    """
    n = len(source)
    depth = 0
    # The last significant character seen, used to tell division from a regex
    # literal, plus the identifier ending there (`return` and friends).
    prev = ""
    word = ""
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
            out.append(source[i:j] if keep_comments else _blank(source[i:j]))
            i = j
            prev = "\n"
            word = ""
            continue
        if ch == "/" and source.startswith("/*", i):
            i = _mask_block_comment(source, i, out, keep_comments)
            prev = " "
            word = ""
            continue
        if ch == '"' or ch == "#":
            start = _string_start(source, i)
            if start is not None:
                hashes, multiline = start
                i = _mask_string(source, i, hashes, multiline, out, keep_comments)
                prev = '"'
                word = ""
                continue
        if ch == "/" and _regex_may_start(prev, word):
            end = _mask_regex(source, i, 0, out)
            if end is not None:
                i = end
                prev = '"'
                word = ""
                continue
        if ch == "#":
            hashes = 0
            while i + hashes < n and source[i + hashes] == "#":
                hashes += 1
            if hashes and i + hashes < n and source[i + hashes] == "/":
                end = _mask_regex(source, i, hashes, out)
                if end is not None:
                    i = end
                    prev = '"'
                    word = ""
                    continue
        if ch == "\n":
            prev = "\n"
            word = ""
        elif ch == "?" and (i == 0 or source[i - 1].isspace()):
            # Swift's ternary `?` is infix and takes whitespace on both sides, so
            # an expression may follow it. A `?` attached to the previous token
            # is postfix optional chaining (`a?.b`) and ends an operand instead.
            prev = TERNARY_QUESTION
            word = ""
        elif not ch.isspace():
            prev = ch
            if ch.isalnum() or ch == "_":
                word += ch
            else:
                word = ""
        out.append(ch)
        i += 1
    return i


# The marker `_mask_code` records for a ternary `?`. It is not a single
# character, so it cannot be confused with the `prev` values read from source.
TERNARY_QUESTION = "? "

# Characters after which a `/` opens a regex literal rather than a division.
# `!` and a postfix `?` are absent: `foo!/Double(n)/2` is a force-unwrap followed
# by a division, and `a?.b / Double(c)` is optional chaining, so a postfix
# operator ends an operand rather than starting one. The infix ternary `?` is
# present, because `flag ? /Double/ : /Float/` starts an expression after it.
REGEX_PREFIXES = "=(,:[&|+-*%<>^~" + TERNARY_QUESTION
REGEX_KEYWORDS = {"return", "case", "in", "where", "is", "as", "try", "match", "guard", "throw"}


def _regex_may_start(prev: str, word: str) -> bool:
    """Report whether a bare ``/`` may open a regex literal.

    A regex may only begin where an expression may begin, which keeps `a / b`,
    `x /= 2` and `a?.b / c` from being read as patterns.
    """
    if prev in {"", "\n"}:
        return True
    if prev in REGEX_PREFIXES:
        return True
    if prev.isalnum() or prev == "_":
        # `return /pattern/`: a keyword, not a divisor.
        return word in REGEX_KEYWORDS
    return False


def mask_code(source: str, keep_comments: bool = False) -> str:
    """Blank out comments and string literals, keeping lines and offsets.

    Everything that is not real code is replaced by spaces so that line
    numbers and column positions stay intact for the regexes. String
    interpolations keep their expression, because that expression is code.
    """
    out: list[str] = []
    _mask_code(source, 0, out, keep_comments=keep_comments)
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

    # A `lint-allow` only counts when the lexer saw it as a real comment, so
    # the directive is read from a pass that keeps comments and drops strings.
    comment_lines = mask_code(text, keep_comments=True).splitlines()
    allows = [allowed_rules(line) for line in comment_lines]
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