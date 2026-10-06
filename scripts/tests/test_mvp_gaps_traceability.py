"""Consistency checks for docs/mvp-gaps-traceability.md.

The traceability document states its verdicts twice: once as a table row per
requirement area, and once as a summary of counts. Three separate reviews found
the two disagreeing, because nothing compared them.

These tests parse the document and assert the two views agree:

- every verdict cell holds one of the four declared values;
- every area number appears in exactly one summary category;
- the number of areas in each summary category equals the number of table rows
  carrying that verdict;
- every area a summary bullet names anywhere, including on a wrapped
  continuation line, belongs to that bullet's own category;
- every path the document cites as evidence actually exists, whatever file type
  it has, except the filename it deliberately names as absent — which must stay
  absent anywhere in the tree, not merely at the repository root;
- every text file under the production source roots carries no asserted-absent
  token, whatever its encoding — including UTF-16, with or without a mark.

The Implemented summary bullet is policed by a pinned list of accepted wordings
rather than by parsing English. Three fix rounds each widened a prose parser and
each widening opened a hole, so the parser is gone; what remains is a
specification of the exact sentences this guard has been shown to be true of.
"""
from __future__ import annotations

import codecs
import re
import shutil
import sys
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
DOC = REPO_ROOT / "docs/mvp-gaps-traceability.md"

DECLARED_VERDICTS = ("implemented", "partial", "scaffold", "unverified")

# Filenames the document deliberately cites as NOT existing, to make a point
# about their absence. Matched by basename anywhere in the tree. Everything else
# the document cites must resolve.
KNOWN_ABSENT = {"Settings.swift"}

# Summary bullets that carry a verdict category and the area numbers it claims.
# The "implemented" bullet is prose about there being none of the ten, so it is
# excluded here and asserted separately.
SUMMARY_VERDICTS = ("partial", "scaffold", "unverified")


def _document() -> str:
    if not DOC.is_file():
        pytest.skip(f"traceability document not present: {DOC.relative_to(REPO_ROOT)}")
    return DOC.read_text(encoding="utf-8")


def _table_rows(text: str) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    for line in text.splitlines():
        match = re.match(r"^\|\s*(\d+)\s*\|(.*)$", line)
        if not match:
            continue
        cells = [cell.strip() for cell in match.group(2).split("|")]
        # cells[0] is the area name (after the number), cells[1] the verdict.
        rows.append((int(match.group(1)), cells[1].replace("*", "").strip()))
    return rows


def _strip_markdown(text: str) -> str:
    """Drop inline emphasis so word matching survives `**bold**` and `_italic_`."""
    return text.replace("*", "").replace("_", "").replace("`", "")


def _summary_bullet_count(text: str, verdict: str) -> int:
    return len(
        re.findall(r"^- \*\*" + verdict + r":\*\*", text, re.MULTILINE | re.IGNORECASE)
    )


def _implemented_bullet_count(text: str) -> int:
    """How many `Implemented` bullets the summary carries.

    Counted separately because its heading is prose ("Implemented end to end
    with a failing-on-break test:") rather than a bare category name, so the
    shared `_summary_bullet_count` pattern does not match it. It still has to be
    exactly one: a second bullet would be ignored by `re.search`, so it could
    claim areas as implemented while every category-union check carried on
    reading only the "none of the ten" bullet.
    """
    return len(
        re.findall(
            r"^- \*\*Implemented end to end[^*]*:\*\*", text, re.MULTILINE | re.IGNORECASE
        )
    )


def _summary_enumeration(text: str, verdict: str) -> list[int]:
    """A category bullet's area list, in order and with duplicates preserved.

    The sequence is kept rather than collapsed to a set: converting to a set
    here would hide `2, 2, 5` before either the table comparison or the
    collision check could see that the summary lists an area twice.
    """
    bullet = _summary_bullet(text, verdict)
    enumeration = re.split(r"[.—]|\n", bullet, maxsplit=1)[0]
    return [int(number) for number in re.findall(r"\d+", enumeration)]


def _summary_areas(text: str, verdict: str) -> set[int]:
    """Area numbers a summary bullet's *category list* claims.

    Only the enumeration is read, not the whole bullet: the bullet may go on to
    say things like "Across all 10 areas ...", and a bare digit search over the
    whole bullet would read that prose as a claim and silently disagree with the
    table. Claims made anywhere else in the bullet are caught by
    ``_summary_bullet_claims`` instead.
    """
    return set(_summary_enumeration(text, verdict))


def _summary_bullet_claims(text: str, verdict: str) -> set[int]:
    """Every area number asserted anywhere inside a category bullet.

    A claim does not have to sit in the enumeration. A bullet that wraps onto a
    continuation line, or adds a sentence after the list, still states areas in
    that category — and if it names an area the table places in a different
    category, the document contradicts itself however quietly it is worded.
    """
    bullet = _summary_bullet(text, verdict)
    return {int(number) for number in re.findall(r"\d+", bullet)}


def test_document_exists() -> None:
    assert DOC.is_file(), f"missing traceability document: {DOC.relative_to(REPO_ROOT)}"


def test_table_has_one_row_per_area() -> None:
    rows = _table_rows(_document())
    assert len(rows) == 10, f"expected 10 requirement areas, found {len(rows)}"
    assert [number for number, _ in rows] == list(range(1, 11))


def test_every_verdict_cell_is_a_declared_value() -> None:
    offenders = [
        f"row {number}: {verdict!r}"
        for number, verdict in _table_rows(_document())
        if verdict not in DECLARED_VERDICTS
    ]
    assert not offenders, f"verdict cells outside the declared values: {offenders}"


def test_each_category_has_exactly_one_summary_bullet() -> None:
    """A second bullet for a category would be silently ignored by a search."""
    text = _document()
    for verdict in ("partial", "scaffold", "unverified"):
        count = _summary_bullet_count(text, verdict)
        assert count == 1, f"expected exactly one {verdict} summary bullet, found {count}"
    implemented = _implemented_bullet_count(text)
    assert implemented == 1, (
        "expected exactly one Implemented summary bullet, found "
        f"{implemented}. A second one would be ignored by the search that reads the "
        "'none of the ten' bullet, so it could claim areas as implemented while "
        "every category-union check carried on agreeing with the table."
    )


def test_no_area_is_listed_twice_in_one_summary_category() -> None:
    """A category list that repeats an area is a claim the table cannot match.

    Reading the enumeration into a set would hide `2, 2, 5` before the table
    comparison saw it, so the sequence is checked against its own unique values.
    """
    offenders = []
    for verdict in SUMMARY_VERDICTS:
        listed = _summary_enumeration(_document(), verdict)
        duplicates = sorted({n for n in listed if listed.count(n) > 1})
        if duplicates:
            offenders.append(f"{verdict}: {duplicates}")
    assert not offenders, f"summary categories list an area more than once: {offenders}"


def test_summary_counts_match_the_table() -> None:
    text = _document()
    rows = _table_rows(text)
    for verdict in SUMMARY_VERDICTS:
        in_table = {number for number, cell in rows if cell == verdict}
        in_summary = _summary_areas(text, verdict)
        assert in_summary == in_table, (
            f"summary and table disagree for {verdict!r}: "
            f"table rows {sorted(in_table)}, summary claims {sorted(in_summary)}"
        )


def test_no_area_is_claimed_by_two_summary_categories() -> None:
    text = _document()
    seen: dict[int, str] = {}
    collisions: list[str] = []
    for verdict in SUMMARY_VERDICTS:
        for number in _summary_areas(text, verdict):
            if number in seen:
                collisions.append(f"area {number}: {seen[number]!r} and {verdict!r}")
            else:
                seen[number] = verdict
    assert not collisions, f"areas claimed by more than one category: {collisions}"


def test_area_claims_inside_a_bullet_belong_to_that_category() -> None:
    """A claim anywhere in a bullet counts, not only the enumeration.

    The enumeration is deliberately read narrowly (see ``_summary_areas``), but
    that narrowness must not become a blind spot: a bullet that wraps onto a
    continuation line and there names an area the table places in another
    category has claimed that area into the wrong category.
    """
    text = _document()
    table = dict(_table_rows(text))
    offenders: list[str] = []
    for verdict in SUMMARY_VERDICTS:
        for number in sorted(_summary_bullet_claims(text, verdict)):
            actual = table.get(number)
            if actual != verdict:
                offenders.append(
                    f"area {number}: claimed as {verdict!r} inside its bullet, "
                    f"but the table says {actual!r}"
                )
    assert not offenders, (
        "summary bullets name areas outside their own category: "
        f"{offenders}. A claim anywhere in the bullet is a claim."
    )


def test_no_area_is_missing_from_the_summary() -> None:
    text = _document()
    claimed = set().union(*(_summary_areas(text, v) for v in SUMMARY_VERDICTS))
    missing = {number for number, _ in _table_rows(text)} - claimed
    assert not missing, f"areas with no summary category: {sorted(missing)}"


def test_implemented_is_reported_as_none_of_the_ten() -> None:
    text = _document()
    rows = _table_rows(text)
    implemented = [number for number, verdict in rows if verdict == "implemented"]
    assert not implemented, (
        f"areas {implemented} are marked implemented; the summary and the "
        "opening prose both state that no area is implemented end to end"
    )
    assert re.search(
        r"^- \*\*Implemented end to end[^*]*:\*\* none of the ten", text, re.MULTILINE
    ), "the summary no longer states that no area is implemented end to end"
    # Whether the bullet's wording is one this guard accepts is a separate
    # question, answered against the pinned list rather than by parsing the
    # sentence: see test_the_implemented_bullet_uses_a_pinned_wording.


# The one sentence this document's Implemented bullet is pinned to. This is the
# wording in `docs/mvp-gaps-traceability.md` as committed; it is held separately
# from the accepted list so that editing the document is a visible diff in this
# constant rather than an extra entry that drifts away from the sentence it
# claims to pin.
PINNED_IMPLEMENTED_WORDING = (
    "Implemented end to end with a failing-on-break test: none of the ten. Areas "
    "5, 8 and 10 contain genuinely implemented machinery (entry amendment, "
    "revisions, export/import/erase) with the surrounding requirement missing."
)

# Wordings the Implemented bullet is allowed to take. Each is a sentence a human
# has read and judged to be true of this document's areas. This is a whitelist,
# not a parser: rewording the bullet makes the guard ask for a human, which is
# the asymmetry this file needs.
#
# The first entry is the document's own wording. The rest are truthful
# rewordings that the prose parser this replaced reported as contradictions: a
# qualifying clause behind a comma, a trailing quantity that is not an area
# number, prose that describes the *machinery* as implemented rather than the
# area, and a connective inside a sentence rather than a bare conjunction. They
# are listed so a legitimate rewording is not rejected, which is the failure mode
# that would get this guard deleted instead of fixed. None of them claims an area
# is implemented; the sentences that do are in CONTRADICTORY_WORDINGS below.
ACCEPTED_IMPLEMENTED_WORDINGS = (
    PINNED_IMPLEMENTED_WORDING,
    # A qualifying clause behind a comma instead of a bare conjunction.
    "Implemented end to end with a failing-on-break test: none of the ten. Areas "
    "5, 8 and 10, while not implemented end to end, contain machinery with the "
    "surrounding requirement missing.",
    # A trailing quantity that is not an area number.
    "Implemented end to end with a failing-on-break test: none of the ten. Areas "
    "5, 8 and 10 contain machinery with the surrounding requirement missing "
    "(3 mechanisms total).",
    # Prose that calls the machinery implemented. The area is still not.
    "Implemented end to end with a failing-on-break test: none of the ten. Areas "
    "5, 8 and 10 contain machinery that is fully implemented with the "
    "surrounding requirement missing.",
    # The document's own sentence with a connective instead of a comma.
    "Implemented end to end with a failing-on-break test: none of the ten. Areas "
    "5, 8 and 10 contain genuinely implemented machinery (entry amendment, "
    "revisions, export/import/erase), but 10 is a special case, with the "
    "surrounding requirement missing.",
)

# Every accepted wording other than the document's own, named so the test that
# guards against false positives reads as a list of the sentences a human has
# checked rather than as a test that happens to pass. Derived from the accepted
# list, because an entry that is not here would be an entry no test has ever
# exercised.
TRUTHFUL_REWORDINGS = ACCEPTED_IMPLEMENTED_WORDINGS[1:]

# Sentences that claim an area *is* implemented, which the table contradicts. The
# parser existed to catch these. Under the pinned design they fail by not being
# in the list, so the test below asserts exactly that: none of them is accepted.
CONTRADICTORY_WORDINGS = (
    (
        "Implemented end to end with a failing-on-break test: none of the ten. "
        "Area 2 is implemented end to end, while Areas 5, 8 and 10 contain "
        "machinery with the surrounding requirement missing.",
        "area 2 is asserted implemented; the table marks it partial",
    ),
    (
        "Implemented end to end with a failing-on-break test: none of the ten. "
        "Area 5 is implemented end to end, while Areas 5, 8 and 10 contain "
        "machinery with the surrounding requirement missing.",
        "area 5 is asserted implemented in the first half and qualified in the "
        "second, which cancels itself out",
    ),
    (
        "Implemented end to end with a failing-on-break test: none of the ten. "
        "Fully implemented is Area 2 with the surrounding requirement missing.",
        "area 2 is asserted implemented",
    ),
    (
        "Implemented end to end with a failing-on-break test: none of the ten. "
        "Areas 2, 5, 8 and 10 contain implemented end-to-end machinery with the "
        "surrounding requirement missing.",
        "area 2 is inside the enumeration the clause governs, and the hyphen in "
        "`end-to-end` hid the assertion from the parser",
    ),
)

_IMPLEMENTED_BULLET = re.compile(
    r"^- \*\*Implemented end to end[^*]*:\*\*(.*?)(?=\n- \*\*|\n#{1,3} |\Z)",
    re.MULTILINE | re.IGNORECASE | re.DOTALL,
)


def _bullet_text(sentence: str) -> str:
    """Wrap a bare sentence the way the document wraps its Implemented bullet.

    The heading is emphasised and the body is not, exactly as the document does
    it, so the round trip through ``_implemented_bullet`` below exercises the
    same reading the document itself goes through rather than a shortcut.
    """
    heading, _, body = sentence.partition(":")
    return f"- **{heading}:**{body}\n"


def _accepted(sentence: str) -> bool:
    """Does this Implemented sentence read back as one this guard accepts?

    The sentence is wrapped into a bullet and read back out again, so a wording
    is only "accepted" if it survives the same round trip the document goes
    through. Comparing strings directly would let an entry be listed that the
    reader could never produce.
    """
    return _implemented_bullet(_bullet_text(sentence)) in ACCEPTED_IMPLEMENTED_WORDINGS


def _implemented_bullet(text: str) -> str:
    """The Implemented summary bullet's sentence, with wrapping collapsed.

    Emphasis is stripped and runs of whitespace collapsed to single spaces, so
    the comparison is against the sentence rather than against the line breaks a
    markdown linter happened to choose. Everything else — word order, the
    qualifying clause, which areas are named — is compared exactly.
    """
    match = _IMPLEMENTED_BULLET.search(text)
    if match is None:
        return ""
    return " ".join(_strip_markdown(match.group(0)).split()).lstrip("- ").strip()


def test_the_implemented_bullet_uses_a_pinned_wording() -> None:
    """The Implemented bullet is held to a pinned list, not to a prose parser.

    Three earlier fix rounds each added a branch to a parser for this bullet and
    each branch opened a hole, in both directions: valid wordings were reported
    as contradictions, and contradictions passed. The parser is gone. What is
    left is a list of the exact sentences this guard has been shown to be true
    of, and anything else stops the suite and asks for a human — which is the
    asymmetry this file needs. Honest documentation is not blocked; it is
    *changed deliberately*, with the change visible in this list.
    """
    found = _implemented_bullet(_document())
    assert found, "the Implemented summary bullet could not be read out of the document"
    assert found in ACCEPTED_IMPLEMENTED_WORDINGS, (
        "the Implemented summary bullet's wording has changed.\n"
        f"\n  now reads: {found!r}\n\n"
        "It is no longer one of the wordings this guard has been shown to be "
        "true of, so a human has to decide whether the new wording is still "
        "truthful — that it names no area as implemented, and that the areas it "
        "does name are qualified the way the table qualifies them. Do not "
        "delete or loosen the check to make this pass.\n\n"
        "The accepted wordings are:\n"
        + "\n".join(f"  - {w!r}" for w in ACCEPTED_IMPLEMENTED_WORDINGS)
        + "\n\nIf the new wording is truthful, add it to "
        "ACCEPTED_IMPLEMENTED_WORDINGS, and if it replaces the document's own "
        "wording, update PINNED_IMPLEMENTED_WORDING to match. Either way, say "
        "in the commit message why the sentence is still true."
    )


def test_the_documents_own_implemented_wording_is_the_pinned_one() -> None:
    """`PINNED_IMPLEMENTED_WORDING` is the document's wording, not a variant.

    Held separately from the list above so that changing the document without
    changing the specification is a visible diff in one constant, rather than an
    extra list entry that drifts away from the sentence it claims to pin.
    """
    assert PINNED_IMPLEMENTED_WORDING in ACCEPTED_IMPLEMENTED_WORDINGS, (
        "PINNED_IMPLEMENTED_WORDING is not in ACCEPTED_IMPLEMENTED_WORDINGS, so "
        "the document's own wording is not among the wordings this guard accepts"
    )
    assert _implemented_bullet(_document()) == PINNED_IMPLEMENTED_WORDING, (
        "the document's Implemented bullet no longer reads as "
        "PINNED_IMPLEMENTED_WORDING. If the new wording is truthful, change the "
        "constant deliberately; that edit is the record of the decision."
    )


def test_truthful_rewordings_the_parser_used_to_reject_are_accepted() -> None:
    """The wordings the old parser reported as unqualified must pass.

    Each of these is a true statement about the same areas, and the parser read
    every one of them as a contradiction: a comma before a qualifying clause, a
    hyphen in `end-to-end`, a quantity that is not an area, and prose describing
    *machinery* as implemented rather than an area. A guard that rejects honest
    documentation gets deleted rather than fixed, so each is pinned here.
    """
    for wording in TRUTHFUL_REWORDINGS:
        assert _accepted(wording), (
            f"a truthful rewording is rejected by the pinned list: {wording!r}. "
            "Add it to ACCEPTED_IMPLEMENTED_WORDINGS with a reason."
        )


def test_contradictory_implemented_wordings_are_rejected() -> None:
    """The contradictions the old parser existed to catch must still fail.

    Under the pinned design they fail simply by not being in the list, which is
    the whole point: there is no English to get wrong. Each of these claims an
    area *is* implemented, which the table contradicts.
    """
    for wording, why in CONTRADICTORY_WORDINGS:
        assert _accepted(wording) is False, (
            f"a contradictory Implemented bullet is accepted: {wording!r} "
            f"({why}). It must not be added to ACCEPTED_IMPLEMENTED_WORDINGS."
        )


def test_a_utf16_resource_hiding_a_token_is_still_found(tmp_path: Path) -> None:
    """A token behind a UTF-16 encoding must not read as absent.

    Decoding UTF-16 as UTF-8 with replacement leaves a NUL between every ASCII
    character, so `"goal" = "Goal";` never contains the substring `goal` and the
    document's absence claim looks true while being false. Byte-order marks are
    handled, and so is unmarked UTF-16 in either endianness — the case a resource
    written by a tool that omits a mark actually arrives in.
    """
    payload = '"goal" = "Goal";\n'
    encodings = {
        "utf-8": payload.encode("utf-8"),
        "utf-8-marked": codecs.BOM_UTF8 + payload.encode("utf-8"),
        "utf-16-le-marked": codecs.BOM_UTF16_LE + payload.encode("utf-16-le"),
        "utf-16-be-marked": codecs.BOM_UTF16_BE + payload.encode("utf-16-be"),
        "utf-16-le-unmarked": payload.encode("utf-16-le"),
        "utf-16-be-unmarked": payload.encode("utf-16-be"),
    }
    for name, raw in encodings.items():
        probe = tmp_path / f"{name}.strings"
        probe.write_bytes(raw)
        read = _read_text(probe).lower()
        assert "goal" in read, (
            f"a {name} resource decodes to {read!r}, which does not contain "
            "'goal'. The document's absence claim would stay green while being "
            "false."
        )
        assert probe in _text_files(tmp_path), (
            f"a {name} resource was skipped by the file discovery, so its "
            "content was never searched"
        )


def test_an_unmarked_utf16_resource_starting_non_ascii_is_still_found(
    tmp_path: Path,
) -> None:
    """Unmarked UTF-16 that does not *begin* with ASCII must still be found.

    The shape evidence used to be "a NUL in every second byte of the sample".
    That holds only while the whole sample is U+0000–U+00FF. A localised
    resource that opens with a CJK character, an accented letter or an emoji has
    a non-zero high byte in its very first code unit, so the every-position
    requirement fails, the file falls back to UTF-8, and the token is never seen:

        file starts with   encoding    detector said   'goal' found
        " (ASCII)          utf-16-le   utf-16-le       True
        食 (CJK)           utf-16-le   None            False
        🍊 (emoji)         utf-16-be   None            False

    A shipped string beginning with a non-Latin character is ordinary for a
    localised app, so both endiannesses and several leading scripts are pinned
    here.
    """
    payload = '"goal" = "Goal";\n'
    leads = {
        "ascii": '"',
        "accented": "é",
        "cyrillic": "Привет",
        "cjk": "食食食",
        "emoji": "\U0001f9ca",
        "mark-after-lead": "﻿",
    }
    for lead_name, lead in leads.items():
        for endianness in ("utf-16-le", "utf-16-be"):
            probe = tmp_path / f"{lead_name}-{endianness}.strings"
            probe.write_bytes((lead + payload).encode(endianness))
            detected = _unmarked_utf16_encoding(probe.read_bytes())
            assert detected == endianness, (
                f"a UTF-16 {endianness} resource beginning with {lead_name!r} was "
                f"read as {detected!r}. Every leading code unit of that text is "
                "outside U+0000–U+00FF, so a rule that needs a NUL in *every* "
                "second byte cannot see the file and the token hides behind it."
            )
            read = _read_text(probe).lower()
            assert "goal" in read, (
                f"a UTF-16 {endianness} resource beginning with {lead_name!r} "
                f"decodes to {read!r}, which does not contain 'goal'."
            )


def test_a_utf8_file_with_embedded_nul_bytes_is_not_read_as_utf16(
    tmp_path: Path,
) -> None:
    """Tolerating non-ASCII must not turn every NUL-bearing file into UTF-16.

    Loosening the old every-position rule is what stops non-ASCII-leading
    resources hiding a token, and it is also the obvious way to make the guard
    read binaries as text: a genuine UTF-8 file containing NUL bytes — a
    NUL-terminated string in a fixture, a padded binary blob — is the case the
    old rule existed to rule out. The replacement still requires evidence that
    survives non-ASCII: the byte parity that would carry the NULs must actually
    be NUL-dominant, the opposite parity must contain none, and the decoded text
    must contain no control characters that text does not have.

    Each case below is a real UTF-8 or binary byte string that must keep reading
    as UTF-8. `utf8-token-and-nuls` is the sharpest of them: it holds the token
    itself, so a misdetection would hide a hit rather than merely mislabel a
    file.
    """
    utf8_cases = {
        "utf8-sprinkled-nuls": b'key\x00value\x00\n',
        "utf8-trailing-nul": b"{}\x00",
        "utf8-token-and-nuls": b'let x = "goal";\x00\x00\x00\n',
        "utf8-padded-json": b'{"goal":"x"}' + b"\x00" * 8,
        "utf8-nul-heavy-tail": b'{"goal":1}\n' + b"\x00" * 48,
        "utf8-tab-separated": b"name\tvalue\tgoal\n",
        "utf8-non-ascii-token": "café naïve goal\n".encode("utf-8"),
    }
    for name, raw in utf8_cases.items():
        detected = _unmarked_utf16_encoding(raw)
        assert detected is None, (
            f"{name} was misreported as {detected!r}. It is a genuine UTF-8 byte "
            "string that merely contains NUL bytes; reading it as UTF-16 would "
            "garble real source and can hide a token the document says is "
            "absent."
        )
        probe = tmp_path / f"{name}.txt"
        probe.write_bytes(raw)
        assert _read_text(probe) == raw.decode("utf-8"), (
            f"{name} did not decode as UTF-8, so the search is reading it as "
            "something else"
        )

    binary_cases = {
        "macho-header": b"\xcf\xfa\xed\xfeAppStorage UserDefaults" + b"\x00" * 64,
        "byte-range": bytes(range(256)),
        "png-header": b"\x89PNG\r\n\x1a\n" + bytes(range(200)),
        "zip-header": b"PK\x03\x04" + b"\x00" * 40 + b"goal" + b"\x00" * 40,
        "mach-o-arm64": b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01" + b"\x00" * 20
        + bytes(range(40)),
    }
    for name, raw in binary_cases.items():
        assert _unmarked_utf16_encoding(raw) is None, (
            f"{name} was reported as UTF-16. The guard would start reading "
            "binaries as text, and a spurious report is the same defect as a "
            "missed one."
        )


def test_a_debug_bundle_beneath_a_source_root_is_not_searched(tmp_path: Path) -> None:
    """A build bundle is not a source file, and its binaries embed symbols.

    `rglob` descends into a `.dSYM` or `.xcarchive` directory and filters only
    the files *inside* it by suffix, so a debug binary's DWARF symbols can match
    a token that no source file contains — reporting a hit that is an artefact
    rather than evidence, which is the same failure as a missed hit. Bundle
    directories are pruned before descent, and a real text file beside one is
    still found, so the pruning is not simply a wider skip.
    """
    root = tmp_path / "Sources"
    dwarf = root / "Widget.dSYM" / "Contents" / "Resources" / "DWARF"
    dwarf.mkdir(parents=True)
    (dwarf / "Widget").write_bytes(
        b"\xcf\xfa\xed\xfe" + b"AppStorage UserDefaults" + b"\x00" * 64
    )
    archive = root / "App.xcarchive" / "Products" / "Applications" / "App"
    archive.parent.mkdir(parents=True)
    archive.write_text('"goal" = "Goal";\n', encoding="utf-8")
    strings = root / "Localizable.strings"
    strings.write_text('"notif" = "Notif";\n', encoding="utf-8")

    found = _text_files(root)
    names = sorted(str(path.relative_to(root)) for path in found)
    assert names == ["Localizable.strings"], (
        "the search should return only the real text file, but returned "
        f"{names}. A bundle's contents must not be searched, and the real file "
        "beside one must still be."
    )
    # And the pruned content really did carry tokens, so this is a bundle being
    # skipped rather than a bundle that would never have matched.
    assert b"AppStorage" in (dwarf / "Widget").read_bytes()
    assert "goal" in archive.read_text(encoding="utf-8")


def test_every_production_source_root_under_ios_is_searched() -> None:
    """No production source tree under `ios/` may go unscanned.

    The zero-match search used a fixed tuple of two trees, so a PR that added a
    third left the suite green while the document's "no code anywhere" claim — and
    the `unverified` verdicts resting on it — went stale. The search now reads
    every source tree under `ios/`, so the question of which trees are production
    cannot arise.

    An earlier version derived the roots from `project.yml` and `Package.swift`
    instead. That is more faithful to what the build ships, and it cost three fix
    rounds of parser findings: a declared `Resources` input missed by a
    convention-based sweep, a configured *file* rejected because the check wanted
    a directory, unhandled `include:` indirection, a nested dependency call, a
    `systemLibrary` target, a target-dependency expression read as a declaration,
    and a checked-in bundle skipped as a build artefact. Each was a new way for
    "production code" to mean something the parser did not recognise, which is
    the wrong failure mode for a guard whose job is to be unable to be wrong.

    Searching a superset of what the document names can only strengthen "these
    tokens appear nowhere in these trees". What must not happen is the reverse, so
    the document's own trees are checked against what the search actually reads.
    """
    _, named = _asserted_evidence_spec()
    searched = _searched_trees()
    assert named, "the evidence note names no trees to search"
    assert searched, (
        "no source tree was found under ios/, so the search is reading nothing. "
        f"The note names {list(named)}, which should have been found."
    )

    for tree in searched:
        assert (REPO_ROOT / tree).is_dir(), (
            f"{tree} is in the search but {(REPO_ROOT / tree)} is not a directory, "
            "so the search reads nothing from it."
        )
    for loose in _searched_root_files():
        assert (REPO_ROOT / loose).is_file(), (
            f"{loose} is in the search but {(REPO_ROOT / loose)} is not a file, so "
            "the search reads nothing from it."
        )

    # The document's own trees must be covered by what the search reads, so the
    # claim it makes is a claim about code this guard actually looked at.
    #
    # Coverage runs both ways, because the two sides are stated at different
    # granularity: the search names one tree per Swift package target under
    # `Sources/`, while the document names the shared `Sources/` parent. Neither
    # spelling encloses the other, so a tree counts as searched when it contains
    # a searched tree, when one of its ancestors is searched, or when it is one.
    uncovered = sorted(tree for tree in named if not _is_covered_by(tree, searched))
    assert not uncovered, (
        f"the evidence note names {uncovered}, which the search does not cover, so "
        "the document is claiming absence over a tree this guard never read. "
        f"Searched trees are {list(searched)}."
    )

    # And the document still has to say the same thing this suite was written
    # against. Dropping a tree from the note would narrow the claim, so it has to
    # be made here deliberately as well as in the document.
    assert named == ASSERTED_ABSENT_TREES, (
        f"the evidence note now claims absence across {list(named)}, but the "
        f"specification this suite is written against is "
        f"{list(ASSERTED_ABSENT_TREES)}. Update both together, and say why in "
        "the document."
    )

@contextmanager
def _repository_rooted_at(root: Path) -> Iterator[None]:
    """Point `REPO_ROOT` at a copied tree for the duration of a mutation.

    The search resolves every path from `REPO_ROOT`, so a probe that plants a file
    in a copy has to move the root with it. Patching the module attribute is what
    lets `_searched_trees` and `_text_files` run against the copy without either
    taking a base path argument.
    """
    with mock.patch.object(sys.modules[__name__], "REPO_ROOT", root):
        yield


def _is_covered_by(tree: str, roots: tuple[str, ...]) -> bool:
    """Is `tree` searched in full by `roots`, or wholly outside all of them?

    Covers both directions of the containment, because the search and the
    document state their trees at different granularity: the search names one
    root per Swift package target under `Sources/`, while the document names the
    shared `Sources/` parent. Half a tree is neither — a root that merely
    overlaps it would leave part of the tree unsearched while the guard reported
    it covered.
    """
    for root in roots:
        if tree == root:
            return True
        if tree.startswith(f"{root}/"):
            return True
        if root.startswith(f"{tree}/"):
            return True
    return False


def _searched_trees() -> tuple[str, ...]:
    """Every production source tree the zero-match search reads.

    **Every** source tree under `ios/`, rather than a set read out of the build
    configuration. An earlier version derived the roots from `project.yml` and
    `Package.swift`, which is more faithful to what the build ships — and which
    spent three fix rounds producing parser findings: a `Resources` input missed
    by a convention-based sweep, then a configured *file* rejected because the
    check wanted a directory, then `include:` indirection, a nested dependency
    call, a `systemLibrary` target, a target-dependency expression read as a
    declaration, and a bundle skipped as a build artefact. Each was a way for
    "production code" to mean something the parser did not recognise.

    Searching all of `ios/` removes the question. A superset can only strengthen
    the document's claim — it says these tokens appear nowhere in the named trees,
    and searching more trees than that leaves the claim true — so the direction
    that matters is closed by construction rather than by a parser being right.

    The cost is that test fixtures are searched too, and they deliberately name
    these tokens. Those live under a `Tests` directory, which is excluded below —
    both where roots are enumerated *and* in `_text_files`, because the roots
    returned here include ancestors, so excluding only the enumeration would leave
    every fixture readable from the directory above it. Excluding a whole `Tests`
    path is the one narrowing here, and it is narrow by name rather than by
    understanding the build.

    A path with a build-output component is skipped however deep it is. The old
    comparison was `path.name == ".build"`, which excluded only the directory
    itself: `swift test` writes `.build/generated`, and that directory was
    returned as a root of its own. `_text_files` then saw paths relative to it, so
    the `.build` component that would have disqualified them was gone by the time
    it decided what to read, and generated sources and binaries were scanned as if
    they were production source.
    """
    ios = REPO_ROOT / "ios"
    assert ios.is_dir(), f"{ios} does not exist, so the search reads nothing"
    found: list[str] = []
    for path in sorted(ios.rglob("*")):
        if not path.is_dir():
            continue
        parts = path.relative_to(REPO_ROOT).parts
        if set(parts) & _BUILD_OUTPUT_DIRS:
            continue
        if set(parts) & _TEST_FIXTURE_DIRS:
            continue
        if _is_skipped_directory(parts):
            continue
        found.append("/".join(parts))
    return tuple(found)


def _searched_root_files() -> tuple[str, ...]:
    """Files sitting directly under `ios/`, which belong to no source tree.

    Discovery returns directories, and `ios` itself is not returned because the
    walk starts at `ios/*`. So a production input that is a *file* directly under
    `ios/` — `ios/Shared.swift`, a shared input a target compiles — is reachable
    from no root at all: not from `ios/HealthNutrition`, which is not its
    ancestor, and not from `ios`, which is not a root. With the repository's
    existing subdirectories the non-empty-search assertion still passes, so the
    miss is silent.

    Held beside `_searched_trees` rather than mixed into it, because the trees are
    asserted to be directories — that assertion is what proves the search reads
    something from each root it names — and a file root would quietly weaken it.
    """
    ios = REPO_ROOT / "ios"
    return tuple(
        "/".join(path.relative_to(REPO_ROOT).parts)
        for path in sorted(ios.iterdir())
        if path.is_file() and path.suffix.lower() not in _TEXT_SKIP_SUFFIXES
    )


def _searched_roots() -> tuple[str, ...]:
    """Every root the zero-match search reads: trees, then loose files."""
    return _searched_trees() + _searched_root_files()


def _searched_paths() -> list[Path]:
    """Every file the zero-match search reads, deduplicated by path.

    A file under a source tree is reachable from its own directory and from each
    ancestor of it, so collecting every root's files yields the same file several
    times. Deduped here so a test can say which files the search reports rather
    than which roots it walked. A root that is a file contributes itself, which is
    how a file sitting directly under `ios/` is read at all.
    """
    found: dict[Path, None] = {}
    for root in _searched_roots():
        base = REPO_ROOT / root
        for path in _text_files(base) if base.is_dir() else [base]:
            found[path] = None
    return sorted(found)


def _token_bearing_files() -> list[str]:
    """Every searched file carrying an asserted-absent token, as a sorted list.

    This is the assertion the search itself makes, factored out so the mutation
    probes can run exactly it against a copied tree: empty against the real
    repository, and naming the planted file against a tree that has one.
    """
    return sorted(
        str(path.relative_to(REPO_ROOT))
        for path in _searched_paths()
        if any(
            token.lower() in _read_text(path).lower()
            for token in ASSERTED_ABSENT_TOKENS
        )
    )


def _copy_ios_tree(destination: Path) -> Path:
    """A writable copy of `ios/`, for mutation tests.

    The probe plants a file in a resource root, so the whole tree is copied rather
    than a single file, and `REPO_ROOT` is repointed at the copy for the duration.
    """
    destination.mkdir(parents=True, exist_ok=True)
    tree = destination / "tree"
    shutil.copytree(REPO_ROOT / "ios", tree / "ios", symlinks=True)
    return tree


def test_a_shipped_resource_root_is_searched(tmp_path: Path) -> None:
    """A token in a `Resources` root the app ships must not read as absent.

    The reproduction this guards against: `project.yml` declares `Resources` as a
    production input of the app target, and a search that recognised only a
    directory named `Sources` never looked inside it, so

        ios/HealthNutrition/Resources/Localizable.strings  ->  "goal" = "Goal";

    left every test green while the document claimed `goal` appears nowhere in
    the app's code.

    The search now reads every source tree under `ios/`, so nothing declares a root
    and nothing can be declared wrong. This keeps the original reproduction as the
    regression it was written for, using the tree it was written about.
    """
    tree = _copy_ios_tree(tmp_path)
    declaration = tree / "ios/HealthNutrition/project.yml"
    assert "path: Resources" in declaration.read_text(encoding="utf-8"), (
        "this test needs project.yml to declare a Resources input; it no longer "
        "does, so the tree it copies is not the one this reproduction describes."
    )
    (tree / "ios/HealthNutrition/Resources").mkdir(parents=True, exist_ok=True)
    planted = tree / "ios/HealthNutrition/Resources/Localizable.strings"
    planted.write_text('"goal" = "Goal";\n', encoding="utf-8")

    with _repository_rooted_at(tree):
        # The same search the assertions run: every tree under `ios/`, plus any
        # file sitting directly under it, deduplicated.
        found = _token_bearing_files()
    assert found == ["ios/HealthNutrition/Resources/Localizable.strings"], (
        "a token planted in a resource root the app ships was not reported; the "
        f"search reported {found}. The document's zero-match claim would be false."
    )


def test_an_ios_test_fixture_naming_an_asserted_token_is_not_searched(
    tmp_path: Path,
) -> None:
    """A test fixture is not production code, and the exclusion must reach it.

    `_searched_trees` skips a root whose path has a `Tests` component, but the
    roots it returns are ancestors as well as leaves: `ios/HealthNutrition` is a
    root, and `_text_files` descends from it without treating `Tests` as a
    skipped directory. So a fixture naming one of these tokens fails the search.

    That is the wrong failure. A fixture that pins the absence of `goal` has to
    name `goal`, so the repository cannot add such a test — and the document's
    claim is about production code, not about fixtures. The exclusion therefore
    has to be effective at the file level, not only where roots are enumerated.
    """
    tree = _copy_ios_tree(tmp_path)
    fixtures = tree / "ios/HealthNutrition/Tests"
    assert fixtures.is_dir(), (
        "this test needs an existing Tests directory under ios/ to plant a fixture "
        f"in; {fixtures.relative_to(tree)} is not one, so the tree it copies is not "
        "the repository this reproduction describes."
    )
    planted = fixtures / "GoalFixture.swift"
    planted.write_text('let goal = "goal"\n', encoding="utf-8")

    with _repository_rooted_at(tree):
        found = _token_bearing_files()

    # The fixture is really there and really names the token, so this is a
    # fixture being skipped rather than a fixture that would never have matched.
    assert "goal" in planted.read_text(encoding="utf-8")
    assert found == [], (
        "a test fixture naming an asserted-absent token was searched, so the "
        f"search reported {found}. The document's claim is about production code: "
        "fixtures deliberately name these tokens, and excluding a `Tests` tree only "
        "where roots are enumerated does not exclude its files."
    )


def test_a_build_directory_beneath_ios_is_not_searched(tmp_path: Path) -> None:
    """A `.build` descendant is build output, and `swift test` creates them.

    The exclusion compared `path.name` to `.build`, so only the directory itself
    was skipped and `swift test` output like `.build/generated` was returned as a
    search root of its own. `_text_files` sees paths relative to that root, so the
    `.build` component that would have disqualified them is gone by the time it
    decides what to read — generated sources and the binaries beside them get
    scanned as if they were production source.

    Every path with a build-output component is excluded instead, which is what
    `_BUILD_OUTPUT_DIRS` says and what `_text_files` already applied.
    """
    tree = _copy_ios_tree(tmp_path)
    generated = tree / "ios/NutritionCore/.build/generated/Sources"
    generated.mkdir(parents=True)
    (generated / "Goal.swift").write_text('let goal = "goal"\n', encoding="utf-8")

    with _repository_rooted_at(tree):
        found = _token_bearing_files()

    assert "goal" in (generated / "Goal.swift").read_text(encoding="utf-8"), (
        "this test needs its planted file to carry the token, or a search that "
        "reads nothing would satisfy it"
    )
    assert found == [], (
        "build output under a `.build` directory was searched, so the search "
        f"reported {found}. Generated sources and binaries are not production "
        "code, and the `.build` component has to disqualify the whole subtree."
    )


def test_a_source_file_directly_under_ios_is_searched(tmp_path: Path) -> None:
    """A production input that is a file, not a tree, must still be searched.

    Discovery returns directories, and `ios` itself is not returned because the
    walk starts at `ios/*`. So a file sitting directly under `ios/` —
    `ios/Shared.swift`, a shared input the app target compiles — is reachable
    from no root at all: not from `ios/HealthNutrition`, which is not its
    ancestor, and not from `ios`, which is not a root.

    With the repository's existing subdirectories the non-empty-search assertion
    still passes, so the miss is silent: the search reports nothing because it
    read something, not because it read everything.
    """
    tree = _copy_ios_tree(tmp_path)
    planted = tree / "ios/Shared.swift"
    planted.write_text('let goal = "goal"\n', encoding="utf-8")

    with _repository_rooted_at(tree):
        found = _token_bearing_files()

    assert found == ["ios/Shared.swift"], (
        "a production file sitting directly under ios/ was not reported; the "
        f"search reported {found}. Discovery returns directories only, so a file "
        "that belongs to no source tree is read by no root."
    )


def test_a_checked_in_resource_bundle_is_searched(tmp_path: Path) -> None:
    """A `.bundle` the repository ships is a production input, not an artefact.

    The suffix filter listed `.bundle` with `.app` and `.dSYM`, so
    `Resources/Help.bundle` and everything under it was excluded twice over:
    skipped as a root, and pruned again when `_text_files` reached it from an
    ancestor. Before this file searched every tree under `ios/` it was searched,
    because a configured root was returned whatever its name.

    The two are told apart by provenance, not by shape — shape cannot, since both
    are a directory with `Contents/` inside it. A generated bundle is one this
    build produced, which means something above it is already excluded: a
    build-output directory, or another bundle the build assembled. A bundle with
    neither is checked in, so it is source the app ships and is searched. So
    `.bundle` comes out of the suffix list entirely and no rule is added for it:
    see the comment on `_GENERATED_BUNDLE_SUFFIXES`.
    """
    tree = _copy_ios_tree(tmp_path)
    resources = tree / "ios/HealthNutrition/Resources/Help.bundle/Contents/Resources"
    resources.mkdir(parents=True)
    (resources / "Help.strings").write_text('"goal" = "Goal";\n', encoding="utf-8")

    with _repository_rooted_at(tree):
        found = _token_bearing_files()

    assert found == [
        "ios/HealthNutrition/Resources/Help.bundle/Contents/Resources/Help.strings"
    ], (
        "the contents of a checked-in .bundle were not searched, so the search "
        f"reported {found}. Unlike a generated .app or .dSYM, a bundle the "
        "repository ships is a production input, and the document's claim covers it."
    )


def test_a_file_named_like_a_skipped_directory_is_still_searched(
    tmp_path: Path,
) -> None:
    """A checked-in file is judged by its suffix, never by its own name.

    Both exclusions are `.gitignore`d as DIRECTORIES, and matching them against every
    path component — including a file's own name — silently skipped a shipped resource
    that happens to be called `build` or `Tests`. Nothing is named that way today, so
    the guard stayed green while a token in a file the app ships was invisible to it.
    """
    assert FILE_NAMES_THAT_MUST_STILL_BE_SEARCHED, (
        "the fixture is empty, so this asserts nothing"
    )
    tree = _copy_ios_tree(tmp_path)
    for name in FILE_NAMES_THAT_MUST_STILL_BE_SEARCHED:
        planted = tree / f"ios/HealthNutrition/Resources/{name}"
        planted.parent.mkdir(parents=True, exist_ok=True)
        assert not planted.is_dir(), (
            f"{name!r} is a directory here, so this no longer describes a file that "
            "merely shares a directory's name"
        )
        planted.write_text('"goal" = "Goal";\n', encoding="utf-8")

    # `_text_files` is where the defect was: it walks from each root and tests every
    # path component, so a FILE's own name matched a directory exclusion. The
    # root-enumeration check tests directories only and was never wrong — `parts`
    # there is always a directory. Reading is asserted directly so the test cannot
    # pass because some other path happened to reach the file.
    for name in FILE_NAMES_THAT_MUST_STILL_BE_SEARCHED:
        planted = tree / f"ios/HealthNutrition/Resources/{name}"
        assert planted in _text_files(planted.parent), (
            f"a shipped resource named {name!r} was not read: a directory exclusion "
            "matched the file's own name. These exclusions name directories, and "
            "only directories."
        )


def test_a_generated_bundle_is_not_searched(tmp_path: Path) -> None:
    """Searching a checked-in bundle must not start searching generated ones.

    A resource bundle a build produced is a build artefact: it lands under a
    build-output directory or inside a bundle the build assembled, and its
    compiled contents embed the symbols this search looks for — the same defect as
    a debug binary under a `.dSYM`. Both cases are planted here, each under
    something already excluded, so the bundle's own name is the only thing not
    doing the work.
    """
    tree = _copy_ios_tree(tmp_path)
    # A bundle inside another bundle the build assembled. `Products` is not a
    # build-output directory name, so nothing but the enclosing-bundle rule can
    # exclude what is inside it.
    assembled = tree / "ios/NutritionCore/Products/App.app/PlugIns/Widget.bundle"
    assembled.mkdir(parents=True)
    (assembled / "goal.txt").write_text("goal\n", encoding="utf-8")
    # And one written straight into a build-output directory.
    loose = tree / "ios/NutritionCore/.build/debug/Generated.bundle/Resources"
    loose.mkdir(parents=True)
    (loose / "Goal.strings").write_text('"goal" = "Goal";\n', encoding="utf-8")

    with _repository_rooted_at(tree):
        found = _token_bearing_files()

    assert found == [], (
        "a bundle produced by a build was searched, so the search reported "
        f"{found}. A bundle under a build-output directory, or inside another "
        "assembled bundle, is an artefact — which is how a generated one is told "
        "apart from a checked-in one."
    )


def test_the_legend_agrees_with_the_table() -> None:
    """The opening legend assigns verdicts to areas in prose too.

    It states twice that areas 1 and 4 are the unverified ones. That is a third
    statement of the same fact, so it is compared with the table rather than
    trusted: prose that names the wrong areas contradicts both other views.
    """
    text = _document()
    table = dict(_table_rows(text))
    match = re.search(
        r"Those rows carry the plain value \*{0,2}(?P<word>[a-z]+)", text
    )
    assert match is not None, (
        "the legend no longer states the verdict value those rows carry"
    )
    legend_verdict = match.group("word").strip("*").lower()
    unverified = {number for number, verdict in table.items() if verdict == "unverified"}
    assert legend_verdict in DECLARED_VERDICTS, (
        f"the legend states {legend_verdict!r}, which is not one of the declared "
        f"verdicts {list(DECLARED_VERDICTS)}"
    )
    assert legend_verdict == "unverified", (
        f"the legend says the rows with no code carry {legend_verdict!r}, while the "
        f"table marks {sorted(unverified)} unverified and the summary agrees with it"
    )

    areas = re.search(r"Two areas \((?P<areas>[^)]*)\)", text)
    assert areas is not None, (
        "the legend no longer names the two areas that have no code behind them"
    )
    named = {int(number) for number in re.findall(r"\d+", areas.group("areas"))}
    assert named == unverified, (
        f"the legend names areas {sorted(named)} as the ones with no code, but the "
        f"table marks {sorted(unverified)} unverified"
    )


# The tokens the document states return zero matches across the two source trees,
# and the trees it names for that claim. Asserting the absence is what stops the
# evidence going stale: the whole workflow is triggered by `ios/**`, so a Swift
# source that starts using one of these would otherwise pass every test here while
# the documented evidence — and the `unverified` verdicts that rest on it — quietly
# became false.
ASSERTED_ABSENT_TOKENS = ("goal", "remind", "notif", "AppStorage", "UserDefaults")
ASSERTED_ABSENT_TREES = (
    "ios/NutritionCore/Sources",
    "ios/HealthNutrition/Sources",
)


def _asserted_evidence_spec() -> tuple[tuple[str, ...], tuple[str, ...]]:
    """The tokens and trees the document claims, read out of the document.

    What is *there* is a separate question, answered by
    ``_configured_production_roots`` and compared with this in
    ``test_every_production_source_root_under_ios_is_searched`` — the claim and
    the repository's shape held apart, so a new production root is reported as
    an unnamed root rather than as a changed document.

    Parsed rather than hard-coded, because a test that verifies a claim while
    searching for something else is worse than no test: replacing `goal` with
    `target` in the note would leave the suite searching for `goal` and passing
    without ever checking the new claim.
    """
    text = _document()
    note = re.search(
        r"return zero matches across (?P<trees>.+?)\.", text, re.DOTALL
    )
    assert note is not None, (
        "the evidence note no longer states which trees the zero-match search "
        "covered"
    )
    trees = tuple(re.findall(r"`([^`]+)`", note.group("trees")))
    # Every code span in the bullet that carries this claim, up to "return zero
    # matches", is a token the document asserts is absent — however many there are
    # and however the bullet wraps, so the list is never half-read.
    bullet = re.search(
        r"^- Absence was established.*?return zero matches across",
        text,
        re.MULTILINE | re.DOTALL,
    )
    assert bullet is not None, (
        "the evidence note no longer states which tokens the zero-match search "
        "covered"
    )
    tokens = tuple(
        span
        for span in re.findall(r"`([^`]+)`", bullet.group(0))
        if "/" not in span
    )
    assert tokens, (
        "the evidence note no longer lists the tokens the zero-match search "
        "covered"
    )
    # Parsing the note means the search always follows the document, which is
    # right — but it also means quietly narrowing the document would quietly
    # narrow the search. These two are the specification the verdicts rest on, so
    # a change to either has to be made here deliberately as well.
    assert tokens == ASSERTED_ABSENT_TOKENS, (
        f"the evidence note now claims {list(tokens)} are absent, but the "
        f"specification this suite is written against is "
        f"{list(ASSERTED_ABSENT_TOKENS)}. Update both together, and say why in "
        "the document."
    )
    # The comparison against ASSERTED_ABSENT_TREES is not made here. It is a
    # claim about the repository's shape as much as about the document, and
    # `test_every_production_source_root_under_ios_is_searched` makes it next to
    # the discovery of the roots that exist, so a new production root is
    # reported as an unnamed root rather than as a changed document.
    return tokens, trees


def test_the_asserted_zero_match_evidence_is_still_zero() -> None:
    """The document's evidence claims are assertions, not commentary.

    "Absence was established by exhaustive search, not by sampling" is the whole
    basis for calling areas 1 and 4 `unverified`, so the search is re-run here
    over the trees the document names. A token that has appeared is reported with
    where it appeared, because the fix is to update the document's verdict and
    this test together rather than to delete the search.

    The search is case-insensitive. Swift spells these `Goal`, `Reminder`,
    `Notification` and `import UserNotifications`, so a case-sensitive check would
    report zero matches for the very code that makes the claim false.
    """
    tokens, trees = _asserted_evidence_spec()
    assert tokens, "the evidence note lists no tokens to search for"
    assert trees, "the evidence note names no trees to search"
    # Search every source tree that exists, not only the two the note names.
    # Searching the named trees alone let a third go unchecked, and the mismatch
    # is reported by ``test_every_production_source_root_under_ios_is_searched``;
    # searching everything means the evidence is true even in the window before
    # that mismatch is fixed.
    for tree in _searched_trees():
        root = REPO_ROOT / tree
        assert root.is_dir(), f"the search names {tree}, which does not exist"
    offenders: set[str] = set()
    # Over every file the search reads, which is every tree plus any file sitting
    # directly under `ios/` — a file belongs to no tree, so it is reached only by
    # the loose-file roots.
    for path in _searched_paths():
        text = _read_text(path).lower()
        for token in tokens:
            if token.lower() in text:
                relative = path.relative_to(REPO_ROOT)
                offenders.add(f"{relative}: {token}")
    assert not offenders, (
        "the document states these tokens return zero matches across "
        f"{list(trees)}, but they now appear:\n  "
        + "\n  ".join(sorted(offenders))
        + "\nIf that is intended, update the document's evidence note and the "
        "verdicts that rest on it."
    )


# Binary and build artefacts are not read. Everything else is: the document claims
# zero matches across the whole tree, not across the Swift files in it, so a JSON
# configuration or a plist carrying one of these tokens has to count too.
_TEXT_SKIP_SUFFIXES = frozenset(
    {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".xcarchive", ".dSYM"}
)

# Directory names that mean build output or tooling scratch rather than source:
# SwiftPM's (`.build`, `.swiftpm`), Xcode's (`DerivedData`, `build`,
# `xcuserdata`), and the repository's own (`.git`, `__pycache__`).
#
# One set, used both to drop a path from the roots `_searched_trees` returns and
# to drop its files in `_text_files`. Two sets would make an exclusion
# root-dependent — a path under `build/` skipped when reached from the directory
# above and read when `build/` was the root it was found under — which is exactly
# the defect a `.build` component caused when only `path.name == ".build"` was
# compared. It is also what tells a generated `.bundle` from a checked-in one,
# which is why it decides provenance rather than only listing SwiftPM's names.
#
# Every name here is ignored by this repository's `.gitignore` or is VCS metadata,
# so nothing checked in lives under one and excluding them cannot hide a production
# input. That is what makes excluding the whole subtree safe, rather than a
# narrowing of the search over source.
_BUILD_OUTPUT_DIRS = frozenset(
    {".build", ".git", ".swiftpm", "__pycache__", "DerivedData", "build", "xcuserdata"}
)
# Every name above is `.gitignore`d as a DIRECTORY, so it is matched against directory
# components only (`parts[:-1]`). Matching a file's own name skipped a checked-in
# resource that happens to be called `build` — `ios/HealthNutrition/Resources/build` —
# which ships and can carry a token the document claims is absent. A file is judged by
# its suffix and by the directories above it, never by its own name.

# Directory names that hold test fixtures rather than production code. Excluded
# because a fixture pinning a token's absence has to name the token — that is what
# a fixture for this document's own claim looks like — while the claim is about
# production code. Narrow by name rather than by understanding the build, and this
# is the one place the search deliberately looks at less than `ios/`. It is applied
# to files as well as to the roots they are discovered under, because the roots
# include ancestors: excluding a `Tests` tree only while enumerating roots excludes
# nothing, because `ios/HealthNutrition` is itself a root and the search descends
# from it straight into the fixtures.
#
# Matched on **directory components only** (`parts[:-1]`), which is what excludes a
# fixture tree while still reading a *file* that happens to be named `Tests`. A
# production target that laid its sources out under a `Tests` directory would be
# skipped by name; no such target exists today, and narrowing to real test-target
# roots would mean asking the build configuration, which this suite deliberately does
# not do because it runs against copies of the tree. The gap fails in the safe
# direction for that hypothetical — a fixture is skipped that should have been read,
# so a token could be missed — which is recorded rather than papered over.
_TEST_FIXTURE_DIRS = frozenset({"Tests"})

# Names that are excluded as DIRECTORIES, planted here as FILES. Both exclusions
# are `.gitignore`d as directories, so a file sharing one of their names is a
# shipped resource, not an artefact.
FILE_NAMES_THAT_MUST_STILL_BE_SEARCHED: tuple[str, ...] = ("build", "Tests")


# Directory names that are build or packaging artefacts rather than source. Held
# separately from the file-suffix set because the same suffix names a directory in
# a bundle and a file elsewhere, and the two are decided differently: a file's own
# suffix is filtered, while a *directory* of this shape disqualifies everything
# beneath it, because filtering the files inside a bundle reads a debug binary's
# symbols as source. Lower-cased before comparison, so a lowercase `.dsym` or
# `.xcarchive` is pruned too.
#
# `.bundle` is deliberately absent, and that is the whole `.bundle` question. A
# checked-in resource bundle is a production input the app ships — `Help.bundle`
# and a strings catalogue are how a bundle reaches a target — while a bundle a
# build produced is an artefact whose compiled contents embed the symbols this
# search looks for, which is the same defect as a debug binary under a `.dSYM`.
# Shape cannot tell them apart: both are a directory with `Contents/` inside it.
#
# Provenance can, so the name is not used and the enclosing path is. A bundle is
# generated exactly when something above it is already excluded — a build-output
# directory or another bundle this build assembled — and both of those are excluded
# by name, so the exclusion needs no special case for `.bundle` at all. What
# matters is only that `.bundle` is not itself in this tuple: a bundle that is
# enclosed by nothing is checked in, and is searched. Both directions are pinned
# by `test_a_checked_in_resource_bundle_is_searched` and
# `test_a_generated_bundle_is_not_searched`.
_GENERATED_BUNDLE_SUFFIXES = (
    ".xcarchive",
    ".dsym",
    ".xcodeproj",
    ".xcworkspace",
    ".app",
    ".framework",
    ".playground",
)


def _is_assembled_bundle(name: str) -> bool:
    """Is this directory name a bundle a build writes, never a source input?

    True for `.app`, `.framework`, `.dSYM`, `.xcarchive`, `.xcodeproj`,
    `.xcworkspace` and `.playground` — names only a build or a generator writes,
    whose contents are binaries and copies of sources already read where they came
    from.
    """
    return name.lower().endswith(_GENERATED_BUNDLE_SUFFIXES)


def _is_skipped_directory(parts: Sequence[str]) -> bool:
    """Is the directory at `parts` excluded, along with everything beneath it?

    Examined component by component, so an exclusion survives the search
    descending from an ancestor root: a `.dSYM` several levels up is still what
    disqualifies the file below it. A bundle this build wrote is excluded for one
    of two reasons, both of them about what is *above* it rather than about its own
    name — a build-output directory, or another bundle this build assembled — so
    both are already covered by the name checks above and nothing here has to
    special-case `.bundle`.

    That asymmetry is deliberate. Excluding an artefact wrongly costs a spurious
    match on a debug binary; excluding a checked-in production bundle wrongly makes
    the document's absence claim false over exactly the files it is about. So the
    narrow reading is the safe one, and a generated bundle that a build happened to
    write into a source tree is searched rather than missed. Distinguishing that
    one would mean asking the version control system, which this suite deliberately
    does not do: it runs against copies of the tree, not against a checkout.
    """
    return any(_is_assembled_bundle(part) for part in parts)


def _unmarked_utf16_encoding(raw: bytes) -> str | None:
    """The UTF-16 endianness of `raw`, if the bytes say so without a mark.

    A mark is the normal case, but `.strings` and XML resources are written by
    tools that omit one, and a UTF-16 resource read as UTF-8 leaves a NUL
    between every ASCII character: the token search finds nothing and the
    document's absence claim looks true while being false.

    A single NUL is not the signal. Requiring one in *every* second byte — which
    this used to do — reads the sample's ASCII-ness as the evidence, and that
    holds only while the sample is entirely U+0000–U+00FF. A localised resource
    that opens with `食`, `é` or an emoji has a non-zero high byte in its first
    code unit, so every-position fails, the file falls back to UTF-8, and a
    token in it hides. This has to survive non-ASCII leads.

    So the evidence is what holds for *every* UTF-16 file regardless of the
    characters in it:

    - the parity that would carry the NUL high bytes is NUL-dominant. ASCII is
      the common case, so that parity is mostly zeros even when the leading
      characters are not ASCII; a file whose high-byte parity is not
      NUL-dominant is not UTF-16 text. Half is the floor: one non-ASCII lead in
      a short sample still leaves the rest dominant, and a genuinely UTF-8 file
      does not have half its bytes zero at one parity by accident.
    - the opposite parity — the one that would carry the character bytes —
      contains no NUL at all. UTF-16 has one byte per code unit, so a NUL there
      is a code unit below U+0100, which is the accidental case: a UTF-8 file
      that merely contains NUL bytes puts them wherever they land, not all at
      one parity.
    - the sample decodes as strict UTF-16. This rejects truncated code units,
      unpaired surrogates and byte orders whose pairs are not code units.
    - the decoded text contains no control characters beyond tab, newline,
      carriage return, form feed and vertical tab. Random and binary bytes
      decode into C1 controls and other unassigned code points, while real
      text does not, and this is what keeps the guard from starting to read
      binaries as text now that the every-position rule is gone.

    Returns None for anything else, including a file too short to sample, so the
    caller falls back to UTF-8 and a binary still degrades to "no match".
    """
    sample = raw[:_UTF16_SAMPLE_BYTES]
    sample = sample[: len(sample) - (len(sample) % 2)]
    if len(sample) < 8:
        return None
    for encoding, high_parity in (("utf-16-le", 1), ("utf-16-be", 0)):
        high = sample[high_parity::2]
        low = sample[1 - high_parity::2]
        zeros = high.count(0)
        # NUL-dominant at this parity, and none at the other.
        if zeros == 0 or zeros * 2 < len(high) or 0 in low:
            continue
        try:
            text = sample.decode(encoding)
        except UnicodeDecodeError:
            continue
        if _is_readable_text(text):
            return encoding
    return None


# How many leading bytes of an unmarked file are sampled for the endianness
# decision. Wider than the old 64 so a short non-ASCII lead is a minority of the
# sample rather than most of it, and so a padded binary blob has enough bytes
# for the control-character check to see something implausible.
_UTF16_SAMPLE_BYTES = 512

# Control characters text may legitimately contain. Everything else in the
# C0/C1 ranges, plus DEL, is treated as evidence that the bytes were not text.
_TEXT_CONTROL_CHARACTERS = frozenset("\t\n\r\f\v")


def _is_readable_text(text: str) -> bool:
    """Is `text` something a source or resource file could plausibly hold?

    Rejects the empty string, unpaired surrogates and surrogates left over from
    a truncated pair, every C0 control other than tab, newline, carriage return,
    form feed and vertical tab, DEL, and the C1 controls. Genuine text survives;
    binary bytes reinterpreted as UTF-16 overwhelmingly do not.
    """
    if not text:
        return False
    for character in text:
        point = ord(character)
        if character in _TEXT_CONTROL_CHARACTERS:
            continue
        if point < 0x20 or point == 0x7F or 0x80 <= point <= 0x9F:
            return False
        if 0xD800 <= point <= 0xDFFF:
            return False
    return True


def _read_text(path: Path) -> str:
    """Read a source file, honouring a byte-order mark in either endianness.

    Reading UTF-16 as UTF-8 with replacement yields a NUL between every ASCII
    character, so `"goal" = "Goal";` never contains the substring `goal` and the
    document's absence claim looks true while being false. A mark is honoured
    for UTF-8, UTF-16 LE and UTF-16 BE, and the mark itself is stripped so it
    cannot fuse with the first token. Unmarked UTF-16 is detected from the
    encoding's own shape — see ``_unmarked_utf16_encoding``.

    Undecodable bytes are replaced rather than raised, so a binary file degrades
    to "no match" instead of failing the suite. No substitution or normalisation
    is applied beyond that: folding characters would let a token match where the
    file does not literally contain it.
    """
    raw = path.read_bytes()
    for bom, encoding in (
        (codecs.BOM_UTF8, "utf-8"),
        (codecs.BOM_UTF16_LE, "utf-16-le"),
        (codecs.BOM_UTF16_BE, "utf-16-be"),
    ):
        if raw.startswith(bom):
            return raw[len(bom) :].decode(encoding, errors="replace")
    encoding = _unmarked_utf16_encoding(raw)
    if encoding is not None:
        return raw.decode(encoding, errors="replace")
    return raw.decode("utf-8", errors="replace")


def _text_files(root: Path) -> list[Path]:
    """Every readable text file under `root`.

    A file is skipped when any *directory* above it is a build artefact, not only
    when the file's own suffix says so. A `.dSYM` or `.xcarchive` beneath a source
    root holds debug binaries whose DWARF symbols embed the very source symbols
    the search is looking for, so the old suffix filter — which only saw the files
    inside the bundle — turned a symbol name into an apparent source match and
    reported a token no source file contains. A spurious report is the same defect
    as a missed one: it sends whoever reads the failure looking for code that does
    not exist.

    `rglob` still walks into a bundle to enumerate it; nothing inside one is
    returned. The match is on the directory components only, so a *file* named
    `Foo.dSYM` is still subject to the ordinary suffix filter.

    Two exclusions are file-level as well as root-level, and have to be, because
    the roots this is called with include ancestors:

    - a `Tests` directory. Excluding it while enumerating roots excludes nothing
      — `ios/HealthNutrition` is itself a root, and this descends through
      `Tests/` to reach the fixtures. A fixture pinning the absence of `goal`
      has to name `goal`, so a root-only exclusion left the repository unable to
      add a test for the very claim this file guards.
    - a build-output directory at any depth, for the same reason: a `.build`
      subtree that was returned as a root of its own is read from that root,
      where the `.build` component is no longer part of the relative path.

    One exclusion is the other way round. A `.bundle` this build produced is
    skipped; a `.bundle` that is checked in is not. The two are told apart by what
    encloses them rather than by the name — see `_is_skipped_directory`.
    """
    found: list[Path] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        parts = path.relative_to(root).parts
        if set(parts[:-1]) & _BUILD_OUTPUT_DIRS:
            continue
        if set(parts[:-1]) & _TEST_FIXTURE_DIRS:
            continue
        if _is_skipped_directory(parts[:-1]):
            continue
        if path.suffix.lower() in _TEXT_SKIP_SUFFIXES:
            continue
        found.append(path)
    return found


def _summary_bullet(text: str, verdict: str) -> str:
    """The full text of a summary bullet, including its wrapped continuation lines.

    A bullet that wraps onto following indented lines must be read whole: the
    contradiction this test guards against is exactly one where the first line
    lists areas and a later line of the same bullet denies that any are listed.
    """
    match = re.search(
        r"^- \*\*" + verdict + r":\*\*(.*?)(?=\n- \*\*|\n#{1,3} |\Z)",
        text,
        re.MULTILINE | re.IGNORECASE | re.DOTALL,
    )
    return _strip_markdown(match.group(1)) if match else ""


def test_summary_does_not_assert_two_different_unverified_claims() -> None:
    """A bullet must not both list unverified areas and say there are none.

    Reads through the shared helpers, so the text is whole-bullet and stripped of
    inline emphasis: the document writes these terms as `**unverified**`, and a
    literal-space pattern would miss an emphasised denial entirely.
    """
    text = _document()
    assert _summary_bullet_count(text, "unverified") == 1, (
        "expected exactly one Unverified summary bullet, "
        f"found {_summary_bullet_count(text, 'unverified')}"
    )
    bullet = _summary_bullet(text, "unverified")
    lists_areas = bool(re.search(r"\d", bullet))
    denies_any = bool(
        re.search(
            r"no area is left unverified|no areas are left unverified"
            r"|there are no unverified|none of the ten are unverified",
            bullet,
            re.IGNORECASE,
        )
    )
    assert not (lists_areas and denies_any), (
        "the Unverified bullet both lists areas and denies that any are unverified:\n"
        f"{bullet.strip()}"
    )


def _cited_path_from_span(span: str) -> str | None:
    """The repository path a code span cites, or None if it cites no path.

    A span may carry more than a bare path: a line number, a line range,
    comma-separated lines, and a trailing symbol — `Units.swift:73
    UnitRegistry`, `TodayViewModel.swift:68-108 load(now:)` and
    `ConnectionsPrivacyView.swift:74,83` are all the same shape of citation.
    So the span is trimmed of everything after the first whitespace or colon,
    and what remains is judged by shape rather than by an extension allowlist:
    an allowlist silently drops any file type nobody thought to list, which is
    how `HealthNutrition.entitlements` came to be unchecked.

    A shape test keeps the symbol-only spans (`Intake.meal`, `DatePicker`) out:
    a citation is a path, so it has a directory separator, and it names a file
    or a directory rather than a bare identifier.
    """
    token = span.strip().split()[0].split(":")[0] if span.strip() else ""
    if "/" not in token or token.startswith(("http:", "https:", "/", "./", "../")):
        return None
    if ".." in token.split("/"):
        return None
    return token


def _cited_paths(text: str) -> set[str]:
    """Every repository path the document cites inside a code span."""
    paths: set[str] = set()
    for match in re.finditer(r"`([^`\n]+)`", text):
        path = _cited_path_from_span(match.group(1))
        if path is not None:
            paths.add(path)
    return paths


def _repository_paths() -> set[str]:
    """Every path under the repository root, relative and posix-shaped."""
    found: set[str] = set()
    for path in REPO_ROOT.rglob("*"):
        parts = path.relative_to(REPO_ROOT).parts
        if parts and parts[0] == ".git":
            continue
        found.add("/".join(parts))
    return found


def test_every_cited_path_exists_except_known_absent() -> None:
    text = _document()
    cited = _cited_paths(text)
    assert cited, "no cited paths were parsed out of the document at all"
    missing = sorted(path for path in cited if not (REPO_ROOT / path).exists())
    assert set(missing) <= KNOWN_ABSENT, (
        f"cited evidence paths do not exist: {missing}. Every extension is "
        "checked, not a fixed list of them, so a citation the parser skipped is "
        "no longer possible."
    )


def test_deliberately_absent_paths_are_still_absent() -> None:
    """An asserted absence is a claim, so it must stop being true loudly.

    The document says the named file does not exist, not that it does not exist
    at the repository root, so the whole tree is searched by basename: dropping
    `Settings.swift` into `ios/HealthNutrition/Sources/` must fail this just as
    loudly as dropping it at the root.
    """
    present = {path for path in _repository_paths() if path.rsplit("/", 1)[-1] in KNOWN_ABSENT}
    assert not present, (
        "the document claims these files do not exist anywhere, but they now do: "
        f"{sorted(present)}. Update the document and KNOWN_ABSENT together, or "
        "delete the file that made the absence claim false."
    )