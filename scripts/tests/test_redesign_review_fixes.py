"""Review follow-ups to the Diary week strip, the entry zoom and the Trends calories card.

- The week strip leaves off a figure whose goal Today hides (Today's rule: a goal switched off on the Goals screen
  keeps its target and totals but shows no bar), for protein and for water, on a journal day and on a Health-only day.
- The zoom back from an entry keeps a real source id: the transition never falls back to an empty string.
- VoiceOver on the Trends calories card says "at least" for a day whose energy is only partly known, as the average
  already does.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
APP = ROOT / "ios/HealthNutrition/Sources"
UT = ROOT / "ios/NutritionCore/Tests/NutritionUITests"


def block(text: str, header: str) -> str:
    start = text.find(header)
    assert start >= 0, f"missing {header!r}"
    nxt = re.search(r"\n    (?:static |private |public |internal |fileprivate )*(?:func|var|struct|enum|init) ",
                    text[start + len(header):])
    return text[start: start + len(header) + (nxt.start() if nxt else len(text))]


def test_strip_figures_can_leave_protein_and_water_off() -> None:
    text = (UI / "JournalViewModel.swift").read_text()
    figures = block(text, "public struct JournalDayFigures")
    assert re.search(r"public let protein:\s*String\?", figures), "JournalDayFigures.protein is optional (nil = hidden)"
    assert re.search(r"public let water:\s*String\?", figures), "JournalDayFigures.water is optional (nil = hidden)"
    body = block(text, "static func stripFigures(")
    assert "hidden.contains" in body, "stripFigures reads the hidden goals it is given"


def test_the_health_only_day_passes_the_goals_and_hidden_set() -> None:
    text = (UI / "DiaryWeekStrip.swift").read_text()
    week = block(text, "public func weekStrip(")
    call = week[week.find("Self.stripFigures("):]
    call = call[: call.find(")\n") + 1]
    assert "hidden: []" not in call and "goals: []" not in call, \
        "the Health-only day builds its figures with the stored goals and the hidden set, not empty ones"


def test_the_strip_view_skips_a_hidden_figure() -> None:
    text = (UI / "DiaryWeekStrip.swift").read_text()
    view = block(text, "private var figures: some View")
    assert re.search(r"if let \w+ = model\.figures\.protein", view), "the Protein figure shows only when not hidden"
    assert re.search(r"if let \w+ = model\.figures\.water", view), "the Water figure shows only when not hidden"


def test_the_zoom_never_falls_back_to_an_empty_id() -> None:
    text = (APP / "RootView.swift").read_text()
    for line in text.splitlines():
        if ".zoom(sourceID:" in line:
            assert '?? ""' not in line, "the zoom source id never falls back to an empty string"


def test_a_partly_known_day_is_spoken_as_at_least() -> None:
    text = (UI / "TrendsSummaryCards.swift").read_text()
    bar = block(text, "public struct Bar:")
    assert re.search(r"public let isPartial:\s*Bool", bar), "TrendsSummary.Bar carries isPartial"
    assert re.search(r"var spokenText:\s*String", bar), "TrendsSummary.Bar words its own spoken text"
    assert "at least" in bar, "a partial day's spoken text says at least"
    assert "spokenText" in text[text.find("private var spokenLabel"):], "the card's spoken label uses Bar.spokenText"


def test_the_unit_tests_exist() -> None:
    strip = (UT / "DiaryWeekStripModelTests.swift").read_text()
    assert "func testAHiddenProteinGoalLeavesProteinOffTheStrip(" in strip
    assert "func testAHiddenWaterGoalLeavesWaterOffTheStrip(" in strip
    trends = (UT / "TrendsSummaryTests.swift").read_text()
    assert "func testAPartlyKnownDayIsSpokenAsAtLeast(" in trends
