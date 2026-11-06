"""Trends in the redesign's style: content cards with icon wells, the Insights week as a Swift Charts bar chart, and
charts that grow with the text size. Content stays what it is today; Insights stays a row the screenshots open.
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



def test_trends_rows_are_content_cards_and_keep_their_names() -> None:
    trends = read("TrendsView.swift")
    assert not OLD_CARD.search(trends)
    assert "ContentCard" in trends and "IconWell(" in trends
    for label in ('"Vitamins and minerals"', '"Insights"', "NavigationLink"):
        assert label in trends, label


def test_the_insights_week_is_a_swift_charts_bar_chart() -> None:
    insights = read("InsightsView.swift")
    assert "import Charts" in insights
    assert "BarMark(" in insights
    assert not OLD_CARD.search(insights)
    assert "ContentCard" in insights
    assert ".frame(height: 96" not in insights
    assert "entries" in insights and "entry" in insights


def test_the_charts_scale_with_the_text_size() -> None:
    for name in ("InsightsView.swift", "WeightTrendChart.swift"):
        text = read(name)
        assert "@ScaledMetric" in text, f"{name} needs a scaled chart height"
    assert ".frame(height: 120)" not in read("WeightTrendChart.swift")


def test_the_vitamins_list_sits_on_the_page_with_card_rows() -> None:
    gaps = read("NutrientGapsView.swift")
    assert "List {" in gaps or "List(" in gaps
    assert ".listRowBackground(TokenColors.card)" in gaps
    assert "TokenColors.page" in gaps
