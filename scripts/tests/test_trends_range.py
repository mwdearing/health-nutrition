"""Trends range: Week, Month and 6 months above the calories and macros cards. Week shows 7 daily bars, Month 30 daily
bars, 6 months 26 weekly bars (each week's average over its counted days). Averages use the Insights rule over the
range; the cards' title says the range.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"


def test_a_range_type_with_three_cases() -> None:
    text = (UI / "TrendsSummaryCards.swift").read_text()
    m = re.search(r"public enum TrendsRange\b[^{]*\{(.*?)\n\}", text, re.S)
    assert m, "TrendsSummaryCards.swift declares public enum TrendsRange"
    body = m.group(1)
    for case in ("week", "month", "sixMonths"):
        assert re.search(rf"case {case}\b", body), case
    for label in ('"Week"', '"Month"', '"6 months"', '"Last 7 days"', '"Last 30 days"', '"Last 6 months"'):
        assert label in body, f"TrendsRange words {label}"


def test_the_summary_takes_a_range() -> None:
    text = (UI / "TrendsSummaryCards.swift").read_text()
    assert re.search(r"static func make\([^)]*range:\s*TrendsRange", text, re.S), "TrendsSummary.make takes a range"
    start = text.find("public struct TrendsCaloriesCard")
    assert start >= 0, "TrendsCaloriesCard is still declared in TrendsSummaryCards.swift"
    cards = text[start:]
    assert '"Last 7 days"' not in cards, "the cards read the range's title, not a fixed 7 days"


def test_the_trends_screen_has_a_segmented_picker() -> None:
    text = (UI / "TrendsView.swift").read_text()
    assert re.search(r"Picker\(\s*\"Range\"", text), "a Picker labelled Range"
    assert ".pickerStyle(.segmented)" in text
    assert "TrendsRange.allCases" in text


def test_the_unit_tests_exist() -> None:
    tests = (ROOT / "ios/NutritionCore/Tests/NutritionUITests/TrendsRangeTests.swift").read_text()
    for name in ("testWeekHasSevenDailyBars", "testMonthHasThirtyDailyBars", "testSixMonthsHasTwentySixWeeklyBars",
                 "testTheAverageCoversTheWholeRange"):
        assert f"func {name}(" in tests, name
