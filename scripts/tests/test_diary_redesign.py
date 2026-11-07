"""The Diary in the redesign's style: the week summary on the hero, each day and meal in content cards, the screen
named "Diary" like its tab, and entry detail as a form on the page colour. Content and navigation stay as they are.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
APP = ROOT / "ios/HealthNutrition/Sources"
OLD_CARD = re.compile(r"(?<![A-Za-z])Card\s*(?:\{|\()")


def struct_body(text: str, header: str) -> str:
    """The source from `header` to the next top-level declaration."""
    start = text.find(header)
    assert start >= 0, f"missing {header!r}"
    rest = text[start + len(header):]
    m = re.search(r"^(?:public |private |fileprivate |internal )?(?:struct|enum|extension|final class|class) ", rest,
                  re.MULTILINE)
    return text[start: start + len(header) + (m.start() if m else len(rest))]


def read(name: str) -> str:
    return (UI / name).read_text()




def region(text: str, start: str) -> str:
    """From `start` to the next member declared at the same indentation."""
    i = text.find(start)
    assert i >= 0, f"missing {start!r}"
    m = re.search(r"\n    (?:private |@ViewBuilder|var |func )", text[i + len(start):])
    return text[i: i + len(start) + (m.start() if m else len(text))]


def test_the_journal_uses_the_hero_and_content_cards() -> None:
    journal = read("JournalView.swift")
    assert not OLD_CARD.search(journal), "JournalView still uses the older Card"
    assert "ContentCard" in journal
    week = region(journal, "func weekSummaryCard(")
    assert "HeroCard" in week
    for role in ("TokenColors.textPrimary", "TokenColors.textSecondary", ".secondary)"):
        assert role not in week, f"the week hero uses the page role {role}"


def test_the_screen_is_named_like_its_tab_and_keeps_its_controls() -> None:
    journal = read("JournalView.swift")
    assert '.navigationTitle("Diary")' in journal
    assert re.search(r"actionTitle:\s*(?:onAdd == nil \? nil : )?AddIntakeAction.title", journal)
    for label in ('"Previous day"', '"Next day"', '"Go to day"'):
        assert label in journal, label


def test_entry_detail_is_a_form_on_the_page_colour() -> None:
    detail = read("EntryDetailView.swift")
    assert not OLD_CARD.search(detail)
    assert ".scrollContentBackground(.hidden)" in detail
    assert "TokenColors.page" in detail
    for label in ('"Delete entry"', '"Log this entry again"', '"Confirm delete"', '"Entry"'):
        assert label in detail, label
