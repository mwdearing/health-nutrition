"""Every text field in NutritionUI sits in a LabeledField or is allowlisted with a reason.

A field's caption is what says what it is for. A bare TextField shows its title only as a placeholder,
which disappears as soon as someone types, so a person can no longer tell what the box holds. The
guard reads the Swift sources and fails on a field that is neither inside a LabeledField call nor listed
in ALLOWLIST below. The walk ignores comments and string literals, so a field named only in prose does
not count.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI_DIR = ROOT / "ios" / "NutritionCore" / "Sources" / "NutritionUI"

# DesignComponents.swift defines LabeledField itself, so its own input plumbing is not a form field.
EXEMPT_FILES = {"DesignComponents.swift"}

# A file whose bare field may stay bare. Each reason is one line; an empty reason fails the test below.
ALLOWLIST = {
    "AddHomeView.swift": "search field in a disabled Later row with no value; nothing is typed into it",
    "GoalsView.swift": "converted in a follow-up: the goals rows are being redesigned separately",
    "AccountSectionView.swift": "converted in a follow-up: the account section changes in its own piece of work",
    "SignInSheet.swift": "converted in a follow-up: the sign-in sheet changes in its own piece of work",
}

FIELD_CALLS = {"TextField", "SecureField", "TextEditor"}
WRAPPER = "LabeledField"


def strip_literals(source: str) -> str:
    """Blank out comments and string literals, keeping every other character and every newline in place."""
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            body = source[i + 1 : j]
            out.append('"' + re.sub(r"[^\n]", " ", body) + '"')
            i = j + 1
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def unwrapped_fields(source: str) -> list[int]:
    """Line numbers of text fields that no enclosing LabeledField call or closure wraps."""
    clean = strip_literals(source)
    stack: list[tuple[str, str | None]] = []
    last_sig = ""
    last_closed: str | None = None
    found: list[int] = []
    i = 0
    while i < len(clean):
        c = clean[i]
        if c.isspace():
            i += 1
            continue
        if c == "(":
            ident = re.search(r"([A-Za-z_]\w*)\s*$", clean[max(0, i - 80) : i])
            name = ident.group(1) if ident else None
            if name in FIELD_CALLS and not any(call == WRAPPER for _, call in stack):
                found.append(clean.count("\n", 0, i) + 1)
            stack.append(("(", name))
        elif c == ")":
            if stack:
                last_closed = stack.pop()[1]
        elif c == "{":
            # A trailing closure belongs to the call that just closed: LabeledField("Name") { ... }.
            stack.append(("{", last_closed if last_sig == ")" else None))
        elif c == "[":
            stack.append(("[", None))
        elif c in "}]":
            if stack:
                stack.pop()
        last_sig = c
        i += 1
    return found


def bare_fields_by_file() -> dict[str, list[int]]:
    result: dict[str, list[int]] = {}
    for path in sorted(UI_DIR.glob("*.swift")):
        if path.name in EXEMPT_FILES:
            continue
        lines = unwrapped_fields(path.read_text(encoding="utf-8"))
        if lines:
            result[path.name] = lines
    return result


def test_every_text_field_is_labeled_or_allowlisted():
    unlisted = {
        name: lines for name, lines in bare_fields_by_file().items() if name not in ALLOWLIST
    }
    assert not unlisted, (
        "bare text fields without a LabeledField caption (wrap them, or allowlist with a reason): "
        + ", ".join(f"{name} lines {', '.join(map(str, lines))}" for name, lines in unlisted.items())
    )


def test_allowlist_entries_have_a_reason_and_still_hold_a_bare_field():
    present = bare_fields_by_file()
    existing = {path.name for path in UI_DIR.glob("*.swift")}
    for name, reason in ALLOWLIST.items():
        assert reason.strip(), f"{name} is allowlisted without a reason"
        # An entry for a file that is not on this branch yet waits for that file to arrive.
        if name in existing:
            assert name in present, f"{name} is allowlisted but has no bare field any more; remove the entry"


def test_wrapped_field_passes_and_bare_field_fails():
    wrapped = (
        'LabeledField("Name") { focus in\n'
        '    TextField(text: $model.name, prompt: Text("For example, Oats")) { Text("Name") }\n'
        "        .focused(focus)\n"
        "}\n"
    )
    bare = 'Section { TextField("Name", text: $model.name) }\n'
    assert unwrapped_fields(wrapped) == []
    assert unwrapped_fields(bare) == [1]


def test_field_named_only_in_prose_is_not_a_field():
    prose = '// TextField("Name", text: $x) is described here\nlet label = "TextField(\\"x\\")"\n'
    assert unwrapped_fields(prose) == []


def test_field_inside_a_labeled_argument_list_passes():
    labeled = 'LabeledField("Amount", error: err, onFocusEnd: {}) { focus in TextField("", text: $a).focused(focus) }\n'
    assert unwrapped_fields(labeled) == []
