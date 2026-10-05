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
  absent anywhere in the tree, not merely at the repository root.
"""
from __future__ import annotations

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

    unqualified = _unqualified_implemented_claims(text)
    assert not unqualified, (
        f"the Implemented bullet names areas {sorted(unqualified)} without saying what is "
        "missing around them, while opening with 'none of the ten'. Either the claim is "
        "qualified the way the other areas are, or it is a contradiction."
    )


# The clause the document uses when it names areas as containing implemented
# machinery whose *requirement* is still missing. An area named in the Implemented
# bullet has to carry it; without it, the bullet claims the area is implemented and
# contradicts both the table and its own opening sentence. This is a whitelist, not
# a parser: rewording the clause makes the guard ask for a human, which is the
# asymmetry this file needs.
_MISSING_REQUIREMENT_CLAUSE = re.compile(
    r"with the surrounding requirement missing", re.IGNORECASE
)


def _unqualified_implemented_claims(text: str) -> set[int]:
    """Areas the Implemented bullet names as implemented without qualifying them.

    "none of the ten" is the number ten in prose, not an area claim, so it is
    removed before the bullet's digits are read.

    The qualification is bound to the *claim*, not to the sentence: an area is
    qualified only when the clause follows that area's own enumeration, so
    appending "Area 2 is implemented end to end;" to a sentence that goes on to
    qualify areas 5, 8 and 10 does not launder the new claim. Sentences that
    carry no area number are prose and contribute nothing either way.
    """
    match = re.search(
        r"^- \*\*Implemented end to end[^*]*:\*\*(.*?)(?=\n- \*\*|\n#{1,3} |\Z)",
        text,
        re.MULTILINE | re.IGNORECASE | re.DOTALL,
    )
    if match is None:
        return set()
    bullet = _strip_markdown(match.group(1)).replace("none of the ten", "")
    unqualified: set[int] = set()
    for sentence in re.split(r"(?<=[.!?])\s+", bullet):
        claimed = {int(number) for number in re.findall(r"\d+", sentence)}
        if not claimed:
            continue
        clause = _MISSING_REQUIREMENT_CLAUSE.search(sentence)
        if clause is not None and not _CLAUSE_BREAKER.search(sentence[: clause.start()]):
            continue
        unqualified |= claimed
    return unqualified


# A claim that is separated from the qualifying clause by a semicolon or a full
# stop is its own claim: "Area 2 is implemented end to end; Areas 5, 8 and 10 ...
# with the surrounding requirement missing" qualifies the areas it governs, not
# the one asserted before the semicolon.
_CLAUSE_BREAKER = re.compile(r"[;.]")


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