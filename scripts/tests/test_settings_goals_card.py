"""Settings opens on a goals card on the hero: the existing Daily goals row grown into a card that shows the daily
energy goal and, when a weight plan exists, the plan in the person's weight unit, with an Edit goals capsule. With no
energy goal it keeps the row's current wording. The whole card is one button that opens the same goals screen.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
CAPTURES = ROOT / "ios/HealthNutrition/Tests/ScreenshotCaptureTests.swift"
CARD = UI / "SettingsGoalsCard.swift"


def test_the_card_has_its_own_file_and_model() -> None:
    assert CARD.exists(), "NutritionUI/SettingsGoalsCard.swift holds the card"
    text = CARD.read_text()
    assert re.search(r"struct SettingsGoalsCard\s*:\s*View", text)
    assert re.search(r"struct SettingsGoalsSummary\b", text), "a plain model builds the lines"
    assert "TokenColors.heroText" in text and "TokenColors.heroSecondaryText" in text
    assert "TokenColors.mint" in text, "the Edit goals capsule is mint"
    assert '"Edit goals"' in text
    assert "IconWell(" in text or "Image(systemName:" in text


def test_settings_uses_the_card_in_the_hero_row() -> None:
    settings = (UI / "AppSettingsView.swift").read_text()
    i = settings.find("SettingsGoalsCard(")
    assert i >= 0, "Settings shows the card"
    near = settings[max(0, i - 400): i + 600]
    assert "showingGoals = true" in near, "the card opens the same goals screen"
    assert ".listRowBackground(TokenColors.hero)" in near
    assert '"Daily goals' in settings + CARD.read_text()


def test_the_card_has_a_capture() -> None:
    assert re.search(r'capture\(\s*"SettingsGoalsCard"', CAPTURES.read_text())
