"""Consistency checks for docs/mvp-gaps-traceability.md.

The traceability document states its verdicts twice: once as a table row per
requirement area, and once as a summary of counts. Three separate reviews found
the two disagreeing, because nothing compared them.

These tests parse the document and assert the two views agree:

- every verdict cell holds one of the four declared values;
- every area number appears in exactly one summary category;
- the number of areas in each summary category equals the number of table rows
  carrying that verdict;
- every path the document cites as evidence actually exists, except the one
  filename it deliberately names as absent.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
DOC = REPO_ROOT / "docs/mvp-gaps-traceability.md"

DECLARED_VERDICTS = ("implemented", "partial", "scaffold", "unverified")

# Filenames the document deliberately cites as NOT existing, to make a point
# about their absence. Everything else must resolve.
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


def _summary_areas(text: str, verdict: str) -> set[int]:
    """Area numbers a summary bullet claims for ``verdict`` (case-insensitive)."""
    areas: set[int] = set()
    pattern = re.compile(
        r"^- \*\*" + verdict + r":\*\*(.*)$", re.MULTILINE | re.IGNORECASE
    )
    for match in pattern.finditer(text):
        for number in re.findall(r"\d+", match.group(1)):
            areas.add(int(number))
    return areas


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
    assert re.search(r"^- \*\*Implemented end to end[^*]*:\*\* none of the ten", text, re.MULTILINE), (
        "the summary no longer states that no area is implemented end to end"
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
    return match.group(1) if match else ""


def test_summary_does_not_assert_two_different_unverified_claims() -> None:
    """A bullet must not both list unverified areas and say there are none."""
    text = _document()
    bullets = re.findall(
        r"^- \*\*Unverified:\*\*(.*?)(?=\n- \*\*|\n#{1,3} |\Z)",
        text,
        re.MULTILINE | re.IGNORECASE | re.DOTALL,
    )
    assert len(bullets) == 1, f"expected one Unverified summary bullet, found {len(bullets)}"
    bullet = bullets[0]
    lists_areas = bool(re.search(r"\d", bullet))
    denies_any = bool(
        re.search(
            r"no area is left unverified|there are no unverified|none of the ten are unverified",
            bullet,
            re.IGNORECASE,
        )
    )
    assert not (lists_areas and denies_any), (
        "the Unverified bullet both lists areas and denies that any are unverified:\n"
        f"{bullet.strip()}"
    )


def _cited_paths(text: str) -> set[str]:
    """Every repository path the document cites inside a code span.

    A span may carry more than a bare path: a line number, a line range, several
    comma-separated lines, and a trailing symbol. All of those forms are citations
    and must be checked, so the closing backtick is allowed to follow any of them
    rather than only an optional single line number.
    """
    return {
        match.group(1)
        for match in re.finditer(
            r"`([A-Za-z0-9_./-]+\.(?:swift|ts|sql|md|yml|json|py))"
            r"(?::[0-9]+(?:[-,][0-9]+)*)?"
            r"(?:\s[^`]*)?`",
            text,
        )
    }


def test_every_cited_path_exists_except_known_absent() -> None:
    text = _document()
    cited = _cited_paths(text)
    missing = sorted(path for path in cited if not (REPO_ROOT / path).exists())
    assert set(missing) <= KNOWN_ABSENT, f"cited evidence paths do not exist: {missing}"


def test_deliberately_absent_paths_are_still_absent() -> None:
    """An asserted absence is a claim, so it must stop being true loudly."""
    present = sorted(path for path in KNOWN_ABSENT if (REPO_ROOT / path).exists())
    assert not present, (
        f"the document claims these do not exist, but they now do: {present}. "
        "Update the document and KNOWN_ABSENT together."
    )