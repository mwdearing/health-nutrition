"""Today's top block is the branded hero: a deep teal card with the calorie ring and the three macro bars.

The hero's content is forced to the dark appearance, so it reads only the hero text roles; a page text role would
fail contrast on the teal (the step 1 review found exactly that). The cards below the hero use ContentCard, and the
identifiers the UI tests and the screenshots find stay as they were.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
HEADER = UI / "NourishTodayHeader.swift"
TODAY = UI / "TodayView.swift"
OLD_CARD = re.compile(r"(?<![A-Za-z])Card\s*(?:\{|\()")
PAGE_ROLES = ("TokenColors.textPrimary", "TokenColors.textSecondary", ".foregroundStyle(.secondary)",
              "TokenColors.surface", "TokenColors.card")


def struct_body(text: str, header: str) -> str:
    """The source from `header` to the next top-level declaration."""
    start = text.find(header)
    assert start >= 0, f"missing {header!r}"
    rest = text[start + len(header):]
    m = re.search(r"^(?:public |private |fileprivate |internal )?(?:struct|enum|extension|final class|class) ", rest,
                  re.MULTILINE)
    return text[start: start + len(header) + (m.start() if m else len(rest))]


def test_the_summary_sits_in_a_hero_card_with_the_ring_and_macro_bars() -> None:
    header = HEADER.read_text()
    assert "HeroCard" in header
    hero = struct_body(header, "private struct TodayHero")
    assert "CalorieRing(" in hero
    assert "onHero: true" in hero
    assert len(re.findall(r"\bMacroBar\(", hero)) >= 1
    assert "MacroColumn(" not in header
    assert '.accessibilityIdentifier("todayHero")' in header


def test_the_hero_uses_only_the_hero_text_roles() -> None:
    hero = struct_body(HEADER.read_text(), "private struct TodayHero")
    for role in PAGE_ROLES:
        assert role not in hero, f"the hero uses the page role {role}"


def test_the_identifiers_and_the_goal_link_stay() -> None:
    header = HEADER.read_text()
    for identifier in ("calorieRemainingFigure", "calorieRemainingLabel", "calorieGoalLine", "calorieFoodBurnedRow",
                       "macroColumn-"):
        assert f'accessibilityIdentifier("{identifier}' in header, identifier
    assert 'Button("Edit goals")' in header
    assert "Set a calorie goal to see what's left" in header
    today = TODAY.read_text()
    for identifier in ("todayHeader", "todayDate"):
        assert f'accessibilityIdentifier("{identifier}")' in today, identifier


def test_the_spoken_summary_is_told_about_entries_without_calories() -> None:
    header = HEADER.read_text()
    calls = [m.start() for m in re.finditer(r"Self\.spokenSummary\(", header)]
    assert calls, "the hero no longer builds the spoken summary"
    for start in calls:
        assert "uncountedEntries:" in header[start: start + 300]


def test_the_cards_below_the_hero_are_content_cards() -> None:
    today = TODAY.read_text()
    assert not OLD_CARD.search(today), "TodayView still uses the older Card"
    assert "goalsCard" not in today
    for name, header in (("SupplementsTodayTile.swift", "struct SupplementsTodayTile"),
                         ("MedicationTodayTile.swift", "struct MedicationsTodayTile"),
                         ("BodyActivity.swift", "public struct BodyActivityCard"),
                         ("FirstDayChecklist.swift", "public struct FirstDayChecklistView")):
        body = struct_body((UI / name).read_text(), header)
        assert not OLD_CARD.search(body), f"{header} still uses the older Card"
        assert "ContentCard" in body, f"{header} should sit in a ContentCard"
    other_goals = HEADER.read_text()
    assert not OLD_CARD.search(other_goals), "the other-goals card should be a ContentCard"


def test_the_empty_day_still_offers_add() -> None:
    today = TODAY.read_text()
    assert '"Nothing logged today"' in today
    assert re.search(r"actionTitle:\s*AddIntakeAction\.title", today)
