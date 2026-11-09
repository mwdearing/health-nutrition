"""The Diary's week strip and the zoom into an entry.

The "This week" hero carries a strip of the seven days the summary covers (day letter, date, a dot on logged days, the
chosen day in mint) and the chosen day's calories, protein and water. A row in the Diary opens the shared entry sheet
with a zoom from that row.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
APP = ROOT / "ios/HealthNutrition/Sources"
CAPTURES = ROOT / "ios/HealthNutrition/Tests/ScreenshotCaptureTests.swift"


def func_body(text: str, header: str) -> str:
    start = text.find(header)
    assert start >= 0, f"missing {header!r}"
    nxt = re.search(r"\n    (?:private |public |internal |fileprivate )?(?:func|var) ", text[start + len(header):])
    return text[start: start + len(header) + (nxt.start() if nxt else len(text))]


def test_the_strip_has_its_own_view_and_model() -> None:
    strip = UI / "DiaryWeekStrip.swift"
    assert strip.exists(), "NutritionUI/DiaryWeekStrip.swift holds the strip"
    text = strip.read_text()
    assert re.search(r"struct DiaryWeekStrip\s*:\s*View", text)
    assert re.search(r"struct DiaryWeekStripModel\b", text)
    assert "TokenColors.mint" in text, "the chosen day is drawn in mint"
    assert "accessibilityLabel" in text


def test_the_strip_sits_in_the_week_hero_and_the_summary_stays() -> None:
    journal = (UI / "JournalView.swift").read_text()
    week = func_body(journal, "private func weekSummaryCard(")
    assert "HeroCard" in week
    assert "DiaryWeekStrip(" in week, "the strip is part of the This week hero"
    assert '"This week"' in week and "week.headline" in week and "week.goalLines" in week, "the summary lines stay"


def test_a_day_tap_reuses_the_jump() -> None:
    journal = (UI / "JournalView.swift").read_text()
    assert "jumpTarget(for:" in journal and "model.reveal(" in journal
    assert journal.count("jumpSerial += 1") >= 3, "the strip jumps the same way as the arrows and the date sheet"


def test_diary_rows_zoom_into_the_entry_sheet() -> None:
    journal = (UI / "JournalView.swift").read_text() + (UI / "EntryRow.swift").read_text()
    assert ".matchedTransitionSource(" in journal, "a Diary row is the zoom's source"
    root = (APP / "RootView.swift").read_text()
    assert ".navigationTransition(.zoom(" in root, "the entry sheet zooms from the row"
    assert "@Namespace" in root


def test_the_strip_has_a_capture() -> None:
    assert re.search(r'capture\(\s*"DiaryWeekStrip"', CAPTURES.read_text())
