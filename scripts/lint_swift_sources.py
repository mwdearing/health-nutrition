#!/usr/bin/env python3
"""Lint Swift sources for the health-nutrition app.

Usage:
    python3 scripts/lint_swift_sources.py [ROOT]

ROOT defaults to ``ios/NutritionCore``. Each finding is reported as
``path:line: rule: message``. The script exits 1 when there is at least one
finding, 0 when the tree is clean and 2 on a usage error.

A run over the package root also lints the app target beside it, so the CI
invocation that names only ``ios/NutritionCore`` covers both SwiftUI surfaces.

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
unlabeled-image
    In the SwiftUI layers: every ``Image(...)`` in a view has to be named for
    VoiceOver. An image is fine when it is built as ``Image(decorative:)``, when
    its own modifier chain carries ``.accessibilityLabel(...)`` or
    ``.accessibilityHidden(true)``, when the control whose label it is carries
    either of those, when it shares a control label with a ``Text`` that names
    it, or when it is a ``Label(title, systemImage:)``, which speaks its own
    title. The package module's scope is ``Sources/NutritionUI/`` only, and the
    app target's is everything under its own ``Sources/``; an enclosing layout is
    not a control, so text beside the image in an ``HStack`` names nothing. A
    control spelled out as ``SwiftUI.Button`` is the same control as ``Button``,
    and a ``Label`` passed both closures as arguments speaks its title just as a
    trailing one does.
    A modifier written on a nested view belongs to that view, so a label inside
    ``Image("photo").overlay { ... }`` or
    ``Image("photo").overlay(content: { ... })`` leaves the outer image unnamed.
    A ``Picker``, ``Menu`` or ``ControlGroup`` closure without a ``label:`` of its
    own holds content rather than a label, so an image among its options needs a
    name of its own; once the content has been passed as ``content:``, though, a
    trailing closure is the control's label. Text hidden with
    ``.accessibilityHidden(true)`` reads nothing aloud and names nothing either,
    even when the hiding is written for one build only. A modifier written inside
    an ``#if`` branch only counts when every configuration that compiles the image
    compiles a name as well.
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
``#"..."#`` is code while a plain ``\\(`` there is text. Both parentheses of an
interpolation are blanked, so the brackets around a literal's contents stay
balanced for the structural scanning the ``unlabeled-image`` rule does.

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

import itertools
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path("ios") / "NutritionCore"

# The SwiftUI surfaces of this repository. A run over the package root also
# covers the app target beside it, so the CI invocation that names only
# `ios/NutritionCore` still lints both.
APP_ROOTS = ("HealthNutrition",)

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

IMAGE_CALL = re.compile(r"\bImage\s*\(")

RULES = (
    "colour-literal",
    "fixed-font",
    "forbidden-import",
    "binary-float",
    "unlabeled-image",
)

MESSAGES = {
    "colour-literal": "hard-coded colour; use the design tokens via TokenColors",
    "fixed-font": "fixed font size; use a Dynamic Type text style",
    "forbidden-import": "forbidden framework use in this layer",
    "binary-float": "binary floating point; use Decimal",
    "unlabeled-image": (
        "image without an accessibility label; add .accessibilityLabel(...) "
        "or mark it decorative with .accessibilityHidden(true)"
    ),
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
                    # Blanked for the same reason as in a string literal.
                    parts.append(" ")
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
                    # The opening parenthesis was blanked above, so the closing
                    # one is blanked too: a masked interpolation stays balanced,
                    # and structural scanning of the surroundings stays correct.
                    out.append(" ")
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


OPENERS = "({["
CLOSERS = ")}]"
TRAILING_LABELS = re.compile(r"(?:label|title|icon|badge)\s*:\s*$")
CHAIN_MEMBER = re.compile(r"\.[A-Za-z_][A-Za-z0-9_]*")
ACCESSIBILITY_LABEL = re.compile(r"\.accessibilityLabel\s*\(")
HIDDEN_TRUE = re.compile(r"\.accessibilityHidden\s*\(\s*true\s*\)")
TEXT_CALL = re.compile(r"\bText\s*\(")
# `Image(decorative:)` declares its own emptiness, so it needs no name.
DECORATIVE_CALL = re.compile(r"\bImage\s*\(\s*decorative\s*:")
# A view whose label closure names what VoiceOver reads. An image inside one of
# these takes the control's accessible name; an image in a plain layout does not,
# because the layout is not something a VoiceOver user operates.
CONTROL_NAMES = frozenset({
    "Button", "Menu", "Toggle", "Label", "Link", "NavigationLink", "Picker",
    "Stepper", "Slider", "DisclosureGroup", "ControlGroup", "EditButton",
})
# Controls whose unlabelled closure holds content rather than a label: the actions
# of a `Menu`, the options of a `Picker`, the views of a `ControlGroup`. A name
# written on such a control names the control, not the items inside it, so an
# image among the items has to be named in its own right. Their `label:` closure
# is a label as usual.
CONTENT_CONTROLS = frozenset({"Menu", "Picker", "ControlGroup"})
# The `content:` argument of such a control, which leaves the trailing closure
# that follows it free to be the label.
CONTENT_ARGUMENT = re.compile(r"\bcontent\s*:")
# `#if`/`#elseif`/`#else`/`#endif`, one per line, indented or not.
DIRECTIVE = re.compile(r"^[ \t]*#(if|elseif|else|endif)\b", re.MULTILINE)
# The same directive read at an offset inside a line, so an indented branch is
# seen as well as one that starts in the first column.
BRANCH_DIRECTIVE = re.compile(r"[ \t]*#(if|elseif|else|endif)\b")
# The line that ends a branch of conditional compilation.
BRANCH_END = re.compile(r"^[ \t]*#(?:elseif|else|endif)\b", re.MULTILINE)


def _match_forward(masked: str, opening: int) -> int:
    """Index of the bracket closing the one at ``opening``, or the end of text."""
    depth = 0
    for index in range(opening, len(masked)):
        char = masked[index]
        if char in OPENERS:
            depth += 1
        elif char in CLOSERS:
            depth -= 1
            if depth == 0:
                return index
    return len(masked)


def _match_backward(masked: str, closing: int) -> int:
    """Index of the bracket opening the one closed at ``closing``."""
    depth = 0
    for index in range(closing, -1, -1):
        char = masked[index]
        if char in CLOSERS:
            depth += 1
        elif char in OPENERS:
            depth -= 1
            if depth == 0:
                return index
    return 0


def _chain_end(masked: str, start: int, bodies: list[tuple[int, int]] | None = None) -> int:
    """End of the member-access chain that begins just after ``start``.

    Each step consumes `.name` plus an optional argument list or trailing
    closure, so modifiers applied to an expression are followed as far as they
    reach. When ``bodies`` is given, the span of each trailing closure consumed
    on the way is collected in it, together with every closure passed as an
    argument: a modifier written inside one of those belongs to the view it is
    applied to, not to the expression the chain started from. That holds for a
    trailing ``.overlay { ... }`` and for ``.overlay(content: { ... })`` alike.
    """
    end = start
    while True:
        index = end
        while index < len(masked) and masked[index].isspace():
            index += 1
        if index >= len(masked) or masked[index] != ".":
            return end
        member = CHAIN_MEMBER.match(masked, index)
        if member is None:
            return end
        index = member.end()
        while index < len(masked) and masked[index].isspace():
            index += 1
        if index < len(masked) and masked[index] in OPENERS:
            closing = _match_forward(masked, index)
            if bodies is not None:
                if masked[index] == "{":
                    # A trailing closure holds the view a modifier is applied to;
                    # an argument list holds its arguments, which are part of this
                    # chain.
                    bodies.append((index, closing))
                else:
                    # A closure passed as an argument, as in `.overlay(content:
                    # { ... })`, holds the nested view just as a trailing closure
                    # does, so a modifier written inside it names that view and not
                    # the expression the chain started from.
                    bodies.extend(_closures_inside(masked, index, closing))
            end = closing + 1
        else:
            end = index


def _closures_inside(masked: str, opening: int, closing: int) -> list[tuple[int, int]]:
    """Spans of the closures written inside the brackets opened at ``opening``."""
    spans: list[tuple[int, int]] = []
    index = opening + 1
    while index < closing:
        if masked[index] == "{":
            end = _match_forward(masked, index)
            spans.append((index, end))
            index = end + 1
            continue
        index += 1
    return spans


def _without_bodies(text: str, base: int, bodies: list[tuple[int, int]]) -> str:
    """``text`` with every span in ``bodies`` blanked, keeping offsets intact.

    The bodies of nested views are blanked so a modifier inside one of them is not
    read as a modifier of the view around it.
    """
    if not bodies:
        return text
    chars = list(text)
    for start, end in bodies:
        for index in range(max(start - base, 0), min(end - base, len(chars))):
            chars[index] = "\n" if chars[index] == "\n" else " "
    return "".join(chars)


def _enclosing_group(masked: str, position: int) -> tuple[int, int] | None:
    """The innermost bracket pair surrounding ``position``, as a span."""
    stack: list[tuple[int, str]] = []
    for index in range(position):
        char = masked[index]
        if char in OPENERS:
            stack.append((index, char))
        elif char in CLOSERS and stack:
            stack.pop()
    if not stack:
        return None
    opening = stack[-1][0]
    return opening, _match_forward(masked, opening)


def _name_start(masked: str, end: int) -> int | None:
    """Start of the identifier ending just before ``end``, or ``None``.

    A qualified name counts as one identifier, so the scan walks over the dots in
    ``SwiftUI.Button`` as well.
    """
    start = end
    while start > 0 and (masked[start - 1].isalnum() or masked[start - 1] in "._"):
        start -= 1
    return None if start == end else start


def _call_start(masked: str, opening: int) -> int:
    """Start of the call whose argument list or trailing closure opens at ``opening``.

    ``Button(action: {}) { ... }`` reaches the name through the argument list the
    closure follows, while ``Menu { ... }`` and ``Button { ... } label: { ... }``
    read it straight in front of the brace.
    """
    i = opening
    while i > 0 and masked[i - 1].isspace():
        i -= 1
    if i > 0 and masked[i - 1] in CLOSERS:
        argument_list = _match_backward(masked, i - 1)
        start = _name_start(masked, argument_list)
        if start is not None:
            return start
        i = argument_list
        while i > 0 and masked[i - 1].isspace():
            i -= 1
    start = _name_start(masked, i)
    return opening if start is None else start


def _control_of(masked: str, opening: int) -> tuple[int, str] | None:
    """The control whose label closure opens at ``opening``, as ``(start, name)``.

    The label of a control is spelled in several ways, and the search steps back
    over each of them in turn: `Button { ... } label: { ... }` labels its second
    trailing closure, `Button(action: {}, label: { ... })` passes it as an
    argument, and `Button(role: .destructive) { ... } label: { ... }` combines an
    argument list with trailing closures, where the step over the separator
    reaches the action closure and through it the call. ``None`` means the
    closure labels nothing.
    """
    position = opening
    while True:
        end = position
        while end > 0 and masked[end - 1].isspace():
            end -= 1
        marker = TRAILING_LABELS.search(masked[:end])
        if marker is not None:
            position = marker.start()
            continue
        if end > 0 and masked[end - 1] == ",":
            # The label was passed as an argument: the argument list it sits in
            # belongs to the control, so read the name off that list.
            separator = end - 1
            group = _enclosing_group(masked, separator)
            if group is not None:
                name = _call_name(masked, group[0])
                if name in CONTROL_NAMES:
                    return _call_start(masked, group[0]), name
            position = separator
            continue
        if end < len(masked) and masked[end] in OPENERS:
            call_open = end
        elif end > 0 and masked[end - 1] in CLOSERS:
            # The tail of an argument list or of an earlier closure of the same
            # control, as in `Button(action: {}) { ... }`.
            call_open = _match_backward(masked, end - 1)
        else:
            return None
        name = _call_name(masked, call_open)
        if name in CONTROL_NAMES:
            return _call_start(masked, call_open), name
        return None


def _closure_label(masked: str, opening: int) -> str:
    """The argument label a trailing closure at ``opening`` is written with."""
    end = opening
    while end > 0 and masked[end - 1].isspace():
        end -= 1
    marker = TRAILING_LABELS.search(masked[:end])
    if marker is None:
        return ""
    return marker.group(0).split(":")[0].strip()


def _is_trailing_closure(masked: str, opening: int) -> bool:
    """Whether the brace at ``opening`` is a trailing closure rather than an argument.

    ``Menu { ... }`` trails its closure, while ``Menu(content: { ... })`` passes
    it as an argument. Both look the same at the brace itself, so the brackets
    around it decide: inside a call's own argument list it is an argument, even
    though a preceding argument closed with ``)``.
    """
    depth = 0
    for index in range(opening - 1, -1, -1):
        char = masked[index]
        if char in CLOSERS:
            depth += 1
        elif char in OPENERS:
            if depth == 0:
                return char != "("
            depth -= 1
    return True


def _content_argument(masked: str, start: int, end: int) -> bool:
    """Whether a ``content:`` argument is written between ``start`` and ``end``.

    The actions of a ``Menu``, the options of a ``Picker`` and the views of a
    ``ControlGroup`` are usually passed as ``content:``, and then the trailing
    closure that follows is the control's label rather than more content.
    """
    return _is_trailing_closure(masked, end) and CONTENT_ARGUMENT.search(masked, start, end) is not None


def _call_name(masked: str, opening: int) -> str:
    """Name of the call whose argument list or trailing closure opens at ``opening``.

    ``Button(action: {}) { ... }`` reaches the name through the argument list,
    ``Button { ... } label: { ... }`` reads it straight before the brace. A
    module-qualified name is spelled out as written, so ``SwiftUI.Button`` and
    ``Button`` come back as one and the same control.
    """
    start = _call_start(masked, opening)
    end = start
    while end < len(masked) and (masked[end].isalnum() or masked[end] in "._"):
        end += 1
    return masked[start:end].split(".")[-1]


def _conditional_blocks(masked: str) -> list[list[tuple[int, int] | None]]:
    """The branches of every conditional-compilation block in the masked source.

    A branch is one ``#if``, ``#elseif`` or ``#else`` arm. A block whose condition
    is false leaves none of its branches compiled, which is the ``None`` entry a
    block without an ``#else`` ends with, so a compiled configuration is exactly
    one entry of every block.
    """
    blocks: list[list[tuple[int, int] | None]] = []
    # Each open block is its branches plus whether an `#else` makes them total.
    stack: list[list] = []
    for match in DIRECTIVE.finditer(masked):
        kind = match.group(1)
        if kind == "if":
            stack.append([[(match.start(), len(masked))], False])
        elif kind in ("elseif", "else"):
            if stack:
                branches = stack[-1][0]
                branches[-1] = (branches[-1][0], match.start())
                branches.append((match.start(), len(masked)))
                stack[-1][1] = stack[-1][1] or kind == "else"
        elif stack:
            branches, exhaustive = stack.pop()
            branches[-1] = (branches[-1][0], match.start())
            if not exhaustive:
                branches.append(None)
            blocks.append(branches)
    # An unterminated block still delimits its branches up to the end of the file.
    for branches, exhaustive in stack:
        if not exhaustive:
            branches.append(None)
        blocks.append(branches)
    return blocks


def _within(span: tuple[int, int], position: int) -> bool:
    return span[0] <= position < span[1]


# Beyond this many branch combinations a set of exemptions cannot be checked
# exactly, so the rule keeps its conservative answer instead of guessing.
CONFIGURATION_LIMIT = 256


def _holds_in_every_build(
    text: str,
    pattern: re.Pattern[str],
    blocks: list[list[tuple[int, int] | None]],
    image: int,
    base: int = 0,
) -> bool:
    """Whether an exemption written in ``text`` survives every build configuration.

    A modifier inside an ``#if` branch only counts when every configuration that
    compiles the image also compiles one, so a label written in debug builds alone
    names nothing in a release build and cannot exempt the image there.
    """
    return _exempts_in_every_build(
        [base + match.start() for match in pattern.finditer(text)], blocks, image
    )


def _exempts_in_every_build(
    offsets: list[int],
    blocks: list[list[tuple[int, int] | None]],
    image: int,
) -> bool:
    """Whether the exemptions written at ``offsets`` hold in every configuration.

    Each offset is one way of naming the image, and the offsets are alternatives:
    a configuration in which none of them is compiled leaves the image unnamed,
    so it cannot be exempted.
    """
    if not offsets:
        return False
    choices = [
        block
        for block in blocks
        if any(
            span is not None and _within(span, offset)
            for offset in [*offsets, image]
            for span in block
        )
    ]
    total = 1
    for block in choices:
        total *= len(block)
    if total > CONFIGURATION_LIMIT:
        return False

    def branches_of(offset: int) -> set[tuple[int, int]]:
        """The compiled entry of every relevant block, were `offset` compiled."""
        return {
            (position, branch)
            for position, block in enumerate(choices)
            for branch, span in enumerate(block)
            if span is not None and _within(span, offset)
        }

    image_branches = branches_of(image)
    candidates = [branches_of(offset) for offset in offsets]
    for combination in itertools.product(*(range(len(block)) for block in choices)):
        chosen = {(position, branch) for position, branch in enumerate(combination)}
        if not image_branches <= chosen:
            # This configuration does not compile the image at all.
            continue
        if not any(candidate <= chosen for candidate in candidates):
            return False
    return True


def _modifier_chain_end(
    masked: str, position: int, bodies: list[tuple[int, int]] | None = None
) -> int:
    """End of a modifier chain, following branches of conditional compilation.

    A control's own modifiers can sit inside an ``#if`` around them, so every
    branch between here and the end of the enclosing block is followed as far as
    its own chain reaches. ``bodies`` collects the closures consumed on the way,
    as in ``_chain_end``.
    """
    end = _chain_end(masked, position, bodies)
    while True:
        line = end
        while line < len(masked) and masked[line].isspace():
            line += 1
        directive = BRANCH_DIRECTIVE.match(masked, line)
        if directive is None:
            return end
        body = directive.end()
        following = BRANCH_END.search(masked, body)
        branch_end = following.start() if following is not None else len(masked)
        end = max(
            end,
            _chain_end(masked, body, bodies),
            _chain_end(masked, branch_end, bodies),
        )


def _call_expression_end(masked: str, start: int, position: int) -> int:
    """Index just past the delimiters of the call written at ``start``.

    ``position`` sits inside that call, so the brackets still open there are the
    control's own: in `Button(action: {}, label: { ... })` the argument list
    outlives the label closure, and the control's modifiers follow it.
    """
    depth = 0
    for index in range(start, position):
        if masked[index] in OPENERS:
            depth += 1
        elif masked[index] in CLOSERS:
            depth -= 1
    while depth > 0:
        end = position
        while end < len(masked) and masked[end].isspace():
            end += 1
        if end >= len(masked) or masked[end] not in CLOSERS:
            break
        depth -= 1
        position = end + 1
    return position


def _first_closure(masked: str, start: int, end: int) -> tuple[int, int] | None:
    """The first closure of the call written in ``masked[start:end]``.

    Braces are counted rather than brackets, so a closure passed as an argument
    counts too: ``Label(title: { ... }, icon: { ... })`` puts the title inside
    the argument list, while ``Label { ... } icon: { ... }`` puts it in a trailing
    closure.
    """
    depth = 0
    for index in range(start, end):
        char = masked[index]
        if char == "{":
            if depth == 0:
                return index, _match_forward(masked, index) + 1
            depth += 1
        elif char == "}":
            depth -= 1
    return None


def _label_window(masked: str, start: int) -> tuple[int, str, list[tuple[int, int]]] | None:
    """The control an ``Image`` is the label of, as ``(start, text, labels)``.

    Nested layouts are climbed through, so an image inside an ``HStack`` inside
    a button label still reaches the button. The text is the control expression,
    which reaches its own modifiers but not the bodies of the views nested in it,
    and the labels are the spans whose text names the control.
    """
    position = start
    while True:
        group = _enclosing_group(masked, position)
        if group is None:
            return None
        opening, closing = group
        control = _control_of(masked, opening)
        if control is None:
            # A plain layout: it names nothing itself, but the control it sits in
            # still may, so keep climbing outwards.
            position = opening
            continue
        control_start, name = control
        if (
            name in CONTENT_CONTROLS
            and not _closure_label(masked, opening)
            and not _content_argument(masked, control_start, opening)
        ):
            # The closure holds the actions or options of the control rather than
            # its label, so it names nothing and the climb goes on outwards. A
            # trailing closure that follows a `content:` argument is the label all
            # the same, because the content has already been passed.
            position = opening
            continue
        bodies: list[tuple[int, int]] = []
        control_end = _modifier_chain_end(
            masked, _call_expression_end(masked, control_start, closing + 1), bodies
        )
        labels = [(opening, closing + 1)]
        if name == "Label":
            title = _first_closure(masked, control_start, control_end)
            if title is not None and title != labels[0]:
                # A `Label` speaks its title, so the title names the image in its
                # icon closure.
                labels.append(title)
        text = _without_bodies(
            masked[control_start:control_end], control_start, [*bodies, *labels]
        )
        return control_start, text, labels


def _visible_texts(masked: str, span: tuple[int, int]) -> list[int]:
    """Offsets of the ``Text`` calls in ``span`` that VoiceOver still reads.

    Text hidden from the accessibility tree reads nothing aloud, so it does not
    name a control either. The modifiers of the text are followed into the
    branches of conditional compilation as well, since a text hidden in one
    branch is still hidden in the builds that compile it.
    """
    offsets = []
    for match in TEXT_CALL.finditer(masked, span[0], span[1]):
        position = match.start()
        bodies: list[tuple[int, int]] = []
        end = _modifier_chain_end(masked, _match_forward(masked, match.end() - 1) + 1, bodies)
        chain = _without_bodies(masked[position:end], position, bodies)
        if HIDDEN_TRUE.search(chain):
            continue
        offsets.append(position)
    return offsets


def unlabeled_images(masked: str) -> list[int]:
    """Offsets of every ``Image(...)`` VoiceOver would meet without a name."""
    blocks = _conditional_blocks(masked)
    found = []
    for match in IMAGE_CALL.finditer(masked):
        start = match.start()
        if DECORATIVE_CALL.match(masked, start):
            # `Image(decorative:)` says so itself.
            continue
        bodies: list[tuple[int, int]] = []
        own_end = _modifier_chain_end(masked, _match_forward(masked, match.end() - 1) + 1, bodies)
        own_chain = _without_bodies(masked[start:own_end], start, bodies)
        if _holds_in_every_build(own_chain, ACCESSIBILITY_LABEL, blocks, start, start):
            continue
        if _holds_in_every_build(own_chain, HIDDEN_TRUE, blocks, start, start):
            # The image declares itself decorative.
            continue
        window = _label_window(masked, start)
        if window is not None:
            control_start, control, labels = window
            if _holds_in_every_build(control, ACCESSIBILITY_LABEL, blocks, start, control_start):
                continue
            if _holds_in_every_build(control, HIDDEN_TRUE, blocks, start, control_start):
                continue
            # Text in the same control label names the control; text in an
            # enclosing layout names something else entirely.
            if any(
                _exempts_in_every_build(_visible_texts(masked, span), blocks, start)
                for span in labels
            ):
                continue
        found.append(start)
    return found


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


def is_view_scope(rel: str, root: Path) -> bool:
    """Whether `rel` is SwiftUI view code the accessibility rules apply to.

    The package module keeps its views under `Sources/NutritionUI/`, and its
    other modules are domain and provider code that never imports SwiftUI, so
    they are out of scope even though they sit under `Sources/` too. The app
    target keeps its own views directly under `Sources/`, which makes every
    file there a view surface.
    """
    posix = rel.replace("\\", "/")
    if root.name in APP_ROOTS:
        return posix.startswith("Sources/")
    return posix.startswith("Sources/NutritionUI/")


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

    # `unlabeled-image` is not a per-module matter: it covers NutritionUI and
    # whatever the app target keeps under its own Sources directory, since both
    # are the SwiftUI surfaces VoiceOver reads.
    if is_view_scope(rel, root):
        for position in unlabeled_images(masked):
            number = line_of(position)
            if number - 1 >= len(allows) or "unlabeled-image" in allows[number - 1]:
                continue
            found[(number, "unlabeled-image")] = None

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


def roots_to_lint(root: Path) -> list[Path]:
    """The roots one run covers: the given one, and the app target beside it.

    CI invokes the linter with the package root, so a rule that applies to the
    app target too has to be enforced from that same invocation; otherwise an
    unlabeled image under `ios/HealthNutrition/Sources` would only ever be
    reported locally.
    """
    roots = [root]
    if root.name not in APP_ROOTS:
        roots.extend(root.parent / name for name in APP_ROOTS if (root.parent / name).is_dir())
    return roots


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else DEFAULT_ROOT
    if not root.is_dir():
        print(f"error: not a directory: {root}", file=sys.stderr)
        return 2
    findings: list[str] = []
    for covered in roots_to_lint(root):
        findings.extend(lint(covered))
    for line in findings:
        print(line)
    if findings:
        print(f"{len(findings)} finding(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))