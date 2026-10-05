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
from pathlib import Path

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
    """No production source root under `ios/` may go unscanned.

    The zero-match search used a fixed tuple of two trees, so a PR that added a
    third production root left the suite green while the document's "no code
    anywhere" claim — and the `unverified` verdicts resting on it — went stale.
    Roots are discovered instead, and the document has to name every one of them.

    Discovery reads the build configuration rather than recognising a directory
    named `Sources`, because that is what the build uses.
    `ios/HealthNutrition/project.yml` declares `Resources` as a production input
    of the app target alongside `Sources`, and a convention-based search skipped
    it — so a localized string shipped in the app could carry a token the
    document claims is absent everywhere while every test here stayed green.

    That makes the document's claim narrower than the search, which is the safe
    direction: searching more than the note names can only strengthen "zero
    matches across these trees". What must not happen is the reverse, so the
    roots are checked three ways — the configuration's own declaration, an
    independent sweep of every declared path, and the document's list.
    """
    _, named = _asserted_evidence_spec()
    configured = _configured_production_roots()
    assert named, "the evidence note names no trees to search"
    assert configured, (
        "no production source root was read from the iOS build configuration, so "
        "the search is reading nothing. The note names "
        f"{list(named)}, which should have been found."
    )

    for tree in configured:
        assert (REPO_ROOT / tree).is_dir(), (
            f"the configuration declares {tree} as a production source root but "
            f"{(REPO_ROOT / tree)} does not exist, so the search reads nothing "
            "from it."
        )

    # Every path the configuration declares, read a second time by a
    # deliberately simpler sweep. This is what makes the test fail when a
    # declared root such as `Resources` is configured but unscanned: the sweep
    # sees `path: Resources` and the search does not, and the two disagree. A
    # check written against the same parser as the discovery would only assert
    # that the parser agrees with itself.
    declared = _independently_declared_paths()
    unscanned = sorted(set(declared) - set(configured))
    assert not unscanned, (
        f"the iOS build configuration declares {unscanned} as production source "
        "roots but the search does not read them. The document claims these "
        f"tokens return zero matches across {list(named)}; a production root "
        "outside the search is a tree the claim was never established over, and "
        "the gap is silent — every test stays green while a shipped resource "
        "carries a token. Read the root in _configured_production_roots, then "
        "update the document's evidence note and ASSERTED_ABSENT_TREES together "
        "and say why in the document."
    )

    # And the document's own trees must be covered by what the search reads, so
    # the claim it makes is a claim about code this guard actually looked at.
    #
    # Coverage runs both ways, because the two sides are stated at different
    # granularity. A Swift package declares one root per *target*
    # (`Sources/NutritionDomain`), while the document names their common parent
    # `ios/NutritionCore/Sources`. Neither spelling encloses the other, so a tree
    # counts as searched when it contains a declared root, when one of its
    # ancestors is a declared root, or when it is one.
    uncovered = sorted(tree for tree in named if not _is_covered_by(tree, configured))
    assert not uncovered, (
        f"the evidence note names {uncovered}, which no declared production "
        f"source root covers. Declared roots are {list(configured)}, so the "
        "document is claiming absence over a tree that is not part of this app."
    )

    # And the document still has to say the same thing this suite was written
    # against. Dropping a tree from the note would narrow the search, so it has
    # to be made here deliberately as well as in the document.
    assert named == ASSERTED_ABSENT_TREES, (
        f"the evidence note now claims absence across {list(named)}, but the "
        f"specification this suite is written against is "
        f"{list(ASSERTED_ABSENT_TREES)}. Update both together, and say why in "
        "the document."
    )


def _is_covered_by(tree: str, roots: tuple[str, ...]) -> bool:
    """Is `tree` searched in full by `roots`, or wholly outside all of them?

    Covers both directions of the containment, because the declaration and the
    document state their trees at different granularity: `Package.swift` names
    one root per target under `Sources/`, while the document names the shared
    `Sources/` parent. Half a tree is neither — a root that merely overlaps it
    would leave part of the tree unsearched while the guard reported it covered.
    """
    for root in roots:
        if tree == root:
            return True
        if tree.startswith(f"{root}/"):
            return True
        if root.startswith(f"{tree}/"):
            return True
    return False


def _independently_declared_paths() -> set[str]:
    """Every production source path the configuration declares, swept naively.

    A second reader, on purpose. ``_configured_production_roots`` reads the
    configuration properly — it tracks targets, skips test bundles and resolves
    ``Sources/<name>`` defaults. This one only looks for ``sources:`` blocks and
    ``path:`` arguments, so it can only ever *over*-report: it names a path the
    real reader skipped, never the reverse. That asymmetry is what makes the
    comparison in
    ``test_every_production_source_root_under_ios_is_searched`` able to fail.

    A test-root path is filtered out of the result rather than the scan
    narrowing: test fixtures deliberately name the tokens this guard looks for,
    so including their targets would fail for a reason that has nothing to do
    with whether a production root is searched.
    """
    found: set[str] = set()
    for config, directory in _configuration_files(REPO_ROOT):
        if config.name == "project.yml":
            declared = _sweep_project_yml(config.read_text(encoding="utf-8"))
        else:
            declared = _sweep_package_swift(config.read_text(encoding="utf-8"))
        for path in declared:
            if "Tests" in Path(path).parts:
                continue
            relative = (directory / path).resolve().relative_to(REPO_ROOT.resolve())
            found.add("/".join(relative.parts))
    return found


def _sweep_project_yml(text: str) -> tuple[str, ...]:
    """Every `- path:` under a `sources:` key, ignoring targets and types."""
    paths: list[str] = []
    collecting = False
    indent = 0
    for raw in text.splitlines():
        line = _strip_yaml_comment(raw).rstrip()
        if not line.strip():
            continue
        column = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if stripped.startswith("-"):
            if collecting and column > indent:
                path = _yaml_value(stripped[2:], "path")
                if path is not None:
                    paths.append(path)
            continue
        if stripped.split(":", 1)[0] == "sources":
            collecting = True
            indent = column
            continue
        if column <= indent:
            collecting = False
    return tuple(paths)


def _sweep_package_swift(text: str) -> tuple[str, ...]:
    """Every production target's path in a manifest, found by plain scanning."""
    paths: list[str] = []
    for match in re.finditer(r"\.(?P<kind>[A-Za-z_][A-Za-z0-9_]*)\s*\(", text):
        kind = match.group("kind")
        if not _is_source_target(kind):
            continue
        body = text[match.end() : text.find(")", match.end()) + 1]
        name = _swift_string(body, "name")
        if name is None:
            continue
        paths.append(_swift_string(body, "path") or f"Sources/{name}")
    return tuple(paths)


def test_a_configured_resource_root_is_searched(tmp_path: Path) -> None:
    """A token in a configured `Resources` root must not read as absent.

    The reproduction this guards against: `project.yml` declares `Resources` as
    a production input of the app target, and a search that recognises only a
    directory named `Sources` never looked inside it, so

        ios/HealthNutrition/Resources/Localizable.strings  ->  "goal" = "Goal";

    passed every test in this file while the document claimed the token appears
    nowhere in production. Dropping that one file into the real tree is the
    planner's reproduction; doing it here on a copy is the same check with no
    risk of leaving a token in the working tree.

    Reading the declaration is what makes this general. `Resources` is not
    special-cased anywhere below: the same code searches the next configured
    input, because the root comes from the configuration rather than from a
    directory name.
    """
    tree = _copy_ios_tree(tmp_path)
    declaration = tree / "ios/HealthNutrition/project.yml"
    assert "path: Resources" in declaration.read_text(encoding="utf-8"), (
        "this test needs project.yml to declare a Resources input; it no longer "
        "does, so either the declaration changed or this reproduction no longer "
        "describes the hole it was written for."
    )
    (tree / "ios/HealthNutrition/Resources").mkdir(parents=True, exist_ok=True)
    planted = tree / "ios/HealthNutrition/Resources/Localizable.strings"
    planted.write_text('"goal" = "Goal";\n', encoding="utf-8")

    tokens = ASSERTED_ABSENT_TOKENS
    searched = _configured_production_roots(tree)
    assert "ios/HealthNutrition/Resources" in searched, (
        f"Resources is declared as a production input but the search reads only "
        f"{list(searched)}, so nothing in it is ever searched."
    )

    found = [
        str(path.relative_to(tree))
        for root in searched
        for path in _text_files(tree / root)
        if any(token.lower() in _read_text(path).lower() for token in tokens)
    ]
    assert found == ["ios/HealthNutrition/Resources/Localizable.strings"], (
        "a token planted in a configured production resource root was not "
        f"reported; the search reported {found}. The document's zero-match claim "
        "is stale while this stays green."
    )


def _copy_ios_tree(destination: Path) -> Path:
    """A writable copy of `ios/` and its configurations, for mutation tests."""
    destination.mkdir(parents=True, exist_ok=True)
    tree = destination / "tree"
    shutil.copytree(REPO_ROOT / "ios", tree / "ios", symlinks=True)
    return tree


def test_an_unreadable_configuration_fails_the_guard_rather_than_searching_less(
    tmp_path: Path,
) -> None:
    """A configuration that cannot be parsed must stop the suite, not shrink it.

    The whole point of reading roots from the configuration is that it cannot be
    quietly mis-read. A parser that caught an error and returned the roots it had
    found so far would turn a malformed `project.yml` into a search over part of
    the app — and into a green suite, because the document's claim is still
    checked against whatever list survived. Half a search and a passing test is
    worse than a failing one: it looks like evidence.

    Each corruption below removes one production root from the search without
    removing it from the build. The shared defect is the same in all three, and
    each case asserts the property rather than the message: no readable subset is
    returned at all.
    """
    corruptions = {
        "a sources entry that is not a path mapping": (
            "      - path: Resources\n",
            "      - excludes: [Ignored]\n",
        ),
        "an inline sources list": (
            "    sources:\n      - path: Sources\n      - path: Resources\n",
            "    sources: [Sources, Resources]\n",
        ),
        "a removed targets section": ("targets:\n", "buildTargets:\n"),
    }
    for description, (before, after) in corruptions.items():
        tree = _copy_ios_tree(tmp_path / description.replace(" ", "_"))
        declaration = tree / "ios/HealthNutrition/project.yml"
        original = declaration.read_text(encoding="utf-8")
        assert before in original, (
            f"this case needs {before!r} in project.yml, which has changed, so it "
            "no longer describes the corruption it was written for"
        )
        declaration.write_text(original.replace(before, after, 1), encoding="utf-8")

        with pytest.raises(UnreadableConfiguration) as caught:
            _configured_production_roots(tree)
        message = str(caught.value)
        assert "project.yml" in message, (
            f"with {description}, the failure did not name the file it could not "
            f"read: {message}"
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


class UnreadableConfiguration(Exception):
    """A build configuration the root discovery cannot read.

    Raised, never swallowed. A configuration the guard cannot parse leaves it
    searching less than the app ships, and a guard that searches less than it
    claims is green while being false — the single failure this whole file
    exists to prevent. Silently carrying on with the roots it did manage to read
    would turn a broken config into a passing suite.
    """


def _configured_production_roots(base: Path | None = None) -> tuple[str, ...]:
    """Every production source root the iOS build configuration declares.

    Derived from the configuration rather than from a directory-name convention,
    because the convention is not what the build uses. `ios/HealthNutrition/
    project.yml` declares *both* `Sources` and `Resources` as production
    inputs of the app target, and a search that recognises only a directory
    literally named `Sources` misses the second — so a localized string
    shipped in the app can carry a token the document claims is absent
    everywhere, and every test in this file stays green.

    Reading the configuration also means the next configured input is picked up
    without anyone remembering to add it here: a resource directory, a fixture
    bundle, a second app target. Each declared root is resolved relative to the
    file that declares it, and test targets are excluded — they are not
    production code, and the fixtures that name these tokens on purpose live
    there.

    `base` exists so the parsing can be exercised against a synthetic tree; the
    default is the repository.
    """
    root = REPO_ROOT if base is None else base
    roots: set[str] = set()
    for config, directory in _configuration_files(root):
        declared = _declared_source_paths(config)
        for path in declared:
            resolved = (directory / path).resolve()
            try:
                relative = resolved.relative_to(root.resolve())
            except ValueError:
                raise UnreadableConfiguration(
                    f"{config.name} declares the production path {path!r}, which "
                    f"resolves to {resolved} — outside the repository. A root the "
                    "search cannot reach is not a root that has been searched."
                ) from None
            roots.add("/".join(relative.parts))
    return tuple(sorted(roots))


def _configuration_files(base: Path) -> list[tuple[Path, Path]]:
    """Every build configuration under `ios/`, with the directory it is relative to.

    Both spellings of the same declaration are read, because both are what this
    project is built from: XcodeGen's `project.yml` for the app target and
    `Package.swift` for the library package. A `Sources` directory that no
    configuration declares is not a production root either — that is the same
    assumption this function replaces, just applied the other way round.
    """
    ios = base / "ios"
    found: list[tuple[Path, Path]] = []
    for name in ("project.yml", "Package.swift"):
        for config in sorted(ios.rglob(name)):
            relative = config.relative_to(base)
            if set(relative.parts) & _TEXT_SKIP_DIRS:
                continue
            found.append((config, config.parent))
    if not found:
        raise UnreadableConfiguration(
            f"no project.yml or Package.swift was found under "
            f"{_display(ios.relative_to(base))}, so no production source root "
            "could be read. The document's zero-match claim is about production "
            "code, and this cannot tell which trees that is."
        )
    return found


def _display(path: Path) -> str:
    return path.as_posix() or "."


def _read_project_yml(text: str, source: str) -> tuple[str, ...]:
    """Every production source path an XcodeGen project file declares.

    Read as the block structure it is — a `targets:` mapping, each target with
    a `type:` and a `sources:` list of `path:` entries — because what is
    being read *is* the build's declaration of what ships. A target whose type
    names a test bundle is skipped, and so is a path through a `Tests`
    directory. A `sources:` list that cannot be resolved to paths is an error
    rather than a partial result: half a target's inputs read is not a search
    over half a target, it is an unknown search.

    The file is read with a small reader rather than a YAML library so that this
    module keeps its only third-party dependency at `pytest`: the
    docs-consistency workflow installs nothing else, and a guard that only works
    on a developer machine is not a guard.
    """
    entries: list[tuple[str, list[str]]] = []
    current: list[str] | None = None
    current_type = ""
    current_indent = 0
    in_targets = False
    saw_targets = False

    def close() -> None:
        nonlocal current, current_type
        if current is not None:
            entries.append((current_type, current))
        current = None
        current_type = ""

    for number, raw in enumerate(text.splitlines(), start=1):
        line = _strip_yaml_comment(raw).rstrip()
        if not line.strip():
            continue
        column = len(line) - len(line.lstrip(" "))
        stripped = line.strip()

        if column == 0:
            key = stripped.split(":", 1)[0]
            if key == "targets":
                in_targets = True
                saw_targets = True
            else:
                if in_targets:
                    close()
                in_targets = False
            continue

        if not in_targets:
            continue

        # A key at or left of the indent that opened the current list ends it,
        # so a `dependencies:` block below `sources:` is not read as more
        # production inputs. Indentation is what separates the two here: both are
        # lists of mappings under the same target, at the same depth.
        if not stripped.startswith("-") and current is not None:
            if column <= current_indent:
                close()

        if stripped.startswith("- "):
            # A list item belongs to the key at the indent above it.
            if current is None:
                continue
            if column <= current_indent:
                continue
            path = _yaml_value(stripped[2:], "path")
            if path is None:
                raise UnreadableConfiguration(
                    f"{source}:{number}: a list item under `sources:` that is not "
                    f"a `path:` mapping ({stripped!r}), so the production input it "
                    "names cannot be searched."
                )
            current.append(path)
            continue

        key, _, rest = stripped.partition(":")
        key = key.strip()
        rest = rest.strip()
        if key == "sources":
            close()
            if rest:
                raise UnreadableConfiguration(
                    f"{source}:{number}: `sources:` written inline ({stripped!r}). "
                    "This reads the block form only, so the production inputs "
                    "would be missed."
                )
            current = []
            current_indent = column
        elif key == "type":
            close()
            current_type = rest.strip("\"'")

    close()
    if not saw_targets:
        raise UnreadableConfiguration(
            f"{source} has no `targets:` section, so the production inputs it "
            "declares cannot be read."
        )

    paths: list[str] = []
    for target_type, declared in entries:
        if not declared:
            raise UnreadableConfiguration(
                f"{source}: a target declares `sources:` but no path could be "
                "read from it, so its production inputs are unknown."
            )
        if "test" in target_type.lower():
            continue
        paths.extend(path for path in declared if "Tests" not in Path(path).parts)
    return tuple(paths)


def _strip_yaml_comment(line: str) -> str:
    """Drop a trailing `#` comment, respecting quoted strings."""
    quote = ""
    for index, character in enumerate(line):
        if quote:
            if character == quote:
                quote = ""
        elif character in "\"'":
            quote = character
        elif character == "#" and (index == 0 or line[index - 1] in " \t"):
            return line[:index]
    return line


def _yaml_value(entry: str, key: str) -> str | None:
    """The value of `key` in a one-line YAML mapping, or None if absent."""
    match = re.match(r"^" + re.escape(key) + r":\s*(?P<value>.*)$", entry)
    if match is None:
        return None
    value = match.group("value").strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


# `PackageDescription` spells its factories in lower camel case — `target`,
# `testTarget` — so the suffix match is case-insensitive.
def _is_source_target(kind: str) -> bool:
    """Is this target factory one that declares a directory of production source?

    `testTarget` and `binaryTarget` are not: test fixtures name the tokens this
    guard looks for on purpose, and a binary target is a prebuilt archive rather
    than source. Anything else ending in `target` is read, including kinds added
    later, so a new target type is searched rather than silently skipped.
    """
    if not kind.lower().endswith("target"):
        return False
    return kind.lower() not in {"testtarget", "binarytarget"}


def _read_package_swift(text: str, source: str) -> tuple[str, ...]:
    """Every production source path a Swift package manifest declares.

    A target's directory is its explicit `path:` where it gives one and
    `Sources/<name>` otherwise — SwiftPM's own default, not a convention
    invented here. Call arguments are read to the matching close parenthesis so
    a declaration spread over several lines is read whole rather than half-read,
    and a target call with no readable name is an error rather than a skipped
    root.
    """
    paths: list[str] = []
    for match in re.finditer(r"\.(?P<kind>[A-Za-z_][A-Za-z0-9_]*)\s*\(", text):
        kind = match.group("kind")
        if not _is_source_target(kind):
            continue
        body = _call_arguments(text, match.end() - 1, source)
        name = _swift_string(body, "name")
        if name is None:
            raise UnreadableConfiguration(
                f"{source}: a `.target(` call declares no name, so its production "
                "path cannot be resolved."
            )
        path = _swift_string(body, "path") or f"Sources/{name}"
        if "Tests" in Path(path).parts:
            continue
        paths.append(path)
    if not paths:
        raise UnreadableConfiguration(
            f"{source}: no production target could be read from this manifest, so "
            "the package's production inputs are unknown."
        )
    return tuple(paths)


def _swift_string(body: str, key: str) -> str | None:
    match = re.search(r"\b" + re.escape(key) + r":\s*\"(?P<value>[^\"]*)\"", body)
    return match.group("value") if match is not None else None


def _call_arguments(text: str, open_index: int, source: str) -> str:
    """The argument text of the call whose `(` sits at `open_index`."""
    depth = 0
    quote = ""
    for index in range(open_index, len(text)):
        character = text[index]
        if quote:
            if character == quote and (index == 0 or text[index - 1] != "\\"):
                quote = ""
            continue
        if character in "\"'":
            quote = character
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1 : index]
    raise UnreadableConfiguration(
        f"{source}: an unterminated call, so its arguments cannot be read."
    )


def _declared_source_paths(config: Path) -> tuple[str, ...]:
    """The production source paths one configuration file declares."""
    text = config.read_text(encoding="utf-8")
    name = config.name
    if name == "project.yml":
        return _read_project_yml(text, name)
    if name == "Package.swift":
        return _read_package_swift(text, name)
    raise UnreadableConfiguration(
        f"{name} is not a configuration this guard knows how to read, so the "
        "production inputs it declares would be missed."
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
    # Search every production source root that exists, not only the two the note
    # names. Searching the named trees alone let a third root go unchecked, and
    # the mismatch is reported by
    # ``test_every_production_source_root_under_ios_is_searched``; searching
    # everything means the evidence is true even in the window before that
    # mismatch is fixed.
    for tree in _configured_production_roots():
        root = REPO_ROOT / tree
        assert root.is_dir(), f"the document names {tree}, which does not exist"
    offenders: list[str] = []
    for tree in _configured_production_roots():
        for path in sorted(_text_files(REPO_ROOT / tree)):
            text = _read_text(path).lower()
            for token in tokens:
                if token.lower() in text:
                    relative = path.relative_to(REPO_ROOT)
                    offenders.append(f"{relative}: {token}")
    assert not offenders, (
        "the document states these tokens return zero matches across "
        f"{list(trees)}, but they now appear:\n  "
        + "\n  ".join(offenders)
        + "\nIf that is intended, update the document's evidence note and the "
        "verdicts that rest on it."
    )


# Binary and build artefacts are not read. Everything else is: the document claims
# zero matches across the whole tree, not across the Swift files in it, so a JSON
# configuration or a plist carrying one of these tokens has to count too.
_TEXT_SKIP_SUFFIXES = frozenset(
    {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".xcarchive", ".dSYM"}
)
_TEXT_SKIP_DIRS = frozenset({".build", ".git", "__pycache__", ".swiftpm"})

# Directory names that are build or packaging artefacts rather than source. Held
# separately from the file-suffix set because the same suffix names a directory in
# a bundle and a file elsewhere, and the two are decided differently: a file's own
# suffix is filtered, while a *directory* of this shape disqualifies everything
# beneath it, because filtering the files inside a bundle reads a debug binary's
# symbols as source. Lower-cased before comparison, so a lowercase `.dsym` or
# `.xcarchive` is pruned too.
_TEXT_SKIP_BUNDLE_SUFFIXES = (
    ".xcarchive",
    ".dsym",
    ".xcodeproj",
    ".xcworkspace",
    ".app",
    ".framework",
    ".bundle",
    ".playground",
)


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

    A file is skipped when any *directory* above it is a build bundle, not only
    when the file's own suffix says so. A `.dSYM` or `.xcarchive` beneath a
    source root holds debug binaries whose DWARF symbols embed the very source
    symbols the search is looking for, so the old suffix filter — which only saw
    the files inside the bundle — turned a symbol name into an apparent source
    match and reported a token no source file contains. A spurious report is the
    same defect as a missed one: it sends whoever reads the failure looking for
    code that does not exist.

    `rglob` still walks into a bundle to enumerate it; nothing inside one is
    returned. The match is on the directory components only, so a *file* named
    `Foo.dSYM` is still subject to the ordinary suffix filter.
    """
    found: list[Path] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        parts = path.relative_to(root).parts
        if set(parts) & _TEXT_SKIP_DIRS:
            continue
        if any(
            part.lower().endswith(_TEXT_SKIP_BUNDLE_SUFFIXES) for part in parts[:-1]
        ):
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