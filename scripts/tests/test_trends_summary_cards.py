"""Trends opens on two summary cards above its rows: a calories card on the hero (daily average, the difference from
the goal, a bar per day with the goal as a rule) and a macros card (one stacked bar and a legend with grams).

Both read the same days and the same averaging rule as Insights, so the two screens never disagree.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
CAPTURES = ROOT / "ios/HealthNutrition/Tests/ScreenshotCaptureTests.swift"
CARDS = UI / "TrendsSummaryCards.swift"


def test_the_cards_have_their_own_file_and_model() -> None:
    assert CARDS.exists(), "NutritionUI/TrendsSummaryCards.swift holds the two cards"
    text = CARDS.read_text()
    assert re.search(r"struct TrendsCaloriesCard\s*:\s*View", text)
    assert re.search(r"struct TrendsMacrosCard\s*:\s*View", text)
    assert re.search(r"struct TrendsSummary\b", text), "a plain model computes the figures"


def test_the_calories_card_is_a_hero_bar_chart_with_a_goal_rule() -> None:
    text = CARDS.read_text()
    assert "import Charts" in text
    assert "HeroCard" in text and "BarMark(" in text and "RuleMark(" in text
    assert "@ScaledMetric" in text, "the chart height scales with the text size"
    assert "TokenColors.heroText" in text


def test_macro_colours_are_fills_not_text() -> None:
    text = CARDS.read_text()
    for token in ("macroProtein", "macroCarbs", "macroFat"):
        assert f"TokenColors.{token}" in text, f"the macros card uses {token}"
    assert not re.search(r"Text\([^)]*\)[^\n]*\n?[^\n]*foregroundStyle\(TokenColors\.macro", text), \
        "macro colours stay fills, never text"


def test_trends_shows_the_cards_above_its_rows() -> None:
    trends = (UI / "TrendsView.swift").read_text()
    calories, macros = trends.find("TrendsCaloriesCard("), trends.find("TrendsMacrosCard(")
    vitamins = trends.find('"Vitamins and minerals"')
    assert calories >= 0 and macros >= 0, "Trends shows both cards"
    assert 0 <= calories < vitamins and macros < vitamins, "the cards come before the rows"
    assert '"Insights"' in trends


def test_trends_and_insights_share_their_days() -> None:
    trends = (UI / "TrendsView.swift").read_text()
    assert trends.count("InsightsAverages.Day(") <= 2, "the Diary-to-days mapping is written once and shared"
    assert "TrendsSummary(" in trends or "TrendsSummary." in trends


def test_the_cards_have_captures() -> None:
    text = CAPTURES.read_text()
    for name in ("TrendsCaloriesCard", "TrendsMacrosCard"):
        assert re.search(rf'capture\(\s*"{name}"', text), f"no capture for {name}"
