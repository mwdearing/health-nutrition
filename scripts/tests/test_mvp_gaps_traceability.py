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
    """
    _, named = _asserted_evidence_spec()
    discovered = _discovered_source_roots()
    assert named, "the evidence note names no trees to search"
    assert discovered, (
        "no production source root was discovered under ios/, so the search is "
        "reading nothing. The note names "
        f"{list(named)}, which should have been found."
    )
    unscanned = sorted(set(discovered) - set(named))
    assert not unscanned, (
        f"production source roots exist under ios/ that the evidence note does "
        f"not name: {unscanned}. The document claims the tokens return zero "
        f"matches across {list(named)}, so a root outside that list is a claim "
        "nobody is checking. Search the new root, then update the document's "
        "evidence note and ASSERTED_ABSENT_TREES together, and say why in the "
        "document."
    )
    missing = sorted(set(named) - set(discovered))
    assert not missing, (
        f"the evidence note names {missing}, which is not a production source "
        f"root under ios/. Discovered roots are {sorted(discovered)}"
    )
    for tree in discovered:
        assert (REPO_ROOT / tree).is_dir(), f"discovered root {tree} does not exist"
    # And the document still has to say the same thing this suite was written
    # against. Dropping a tree from the note would narrow the search, so it has
    # to be made here deliberately as well as in the document.
    assert named == ASSERTED_ABSENT_TREES, (
        f"the evidence note now claims absence across {list(named)}, but the "
        f"specification this suite is written against is "
        f"{list(ASSERTED_ABSENT_TREES)}. Update both together, and say why in "
        "the document."
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


def _discovered_source_roots() -> tuple[str, ...]:
    """Every production source root under `ios/`, discovered rather than listed.

    The zero-match claim is a claim about production code, so a root that this
    tuple of two named trees does not contain is a tree nobody is checking. A
    Swift package or app target is recognised by its `Sources` directory, which
    is the convention both existing roots follow and the one `project.yml` and
    `Package.swift` generate from. Test roots are excluded: they are not
    production code, and the fixtures that name these tokens on purpose live
    there.
    """
    roots = []
    for path in sorted((REPO_ROOT / "ios").rglob("Sources")):
        if not path.is_dir():
            continue
        relative = path.relative_to(REPO_ROOT)
        if set(relative.parts) & _TEXT_SKIP_DIRS:
            continue
        if "Tests" in relative.parts:
            continue
        roots.append("/".join(relative.parts))
    return tuple(sorted(roots))


def _asserted_evidence_spec() -> tuple[tuple[str, ...], tuple[str, ...]]:
    """The tokens and trees the document claims, read out of the document.

    What is *there* is a separate question, answered by
    ``_discovered_source_roots`` and compared with this in
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
    for tree in _discovered_source_roots():
        root = REPO_ROOT / tree
        assert root.is_dir(), f"the document names {tree}, which does not exist"
    offenders: list[str] = []
    for tree in _discovered_source_roots():
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

    The signal is a NUL in *every* second byte of the leading sample, in one
    parity only. That is not a guess about content, it is the encoding's own
    shape: ASCII-range text in UTF-16 has a NUL in the high or low byte of each
    code unit, and a genuine UTF-8 file containing NUL bytes does not do this in
    one parity across a whole sample. Requiring every position rules out the
    accidental case, which is the one a false report would come from.

    Returns None for anything else, including a file too short to sample, so the
    caller falls back to UTF-8 and a binary still degrades to "no match".
    """
    sample = raw[:64]
    if len(sample) < 8 or b"\x00" not in sample:
        return None
    if all(byte == 0 for byte in sample[1::2]):
        return "utf-16-le"
    if all(byte == 0 for byte in sample[0::2]):
        return "utf-16-be"
    return None


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