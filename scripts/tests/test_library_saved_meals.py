"""The Library's saved meals: a row of cards under the segments (the first on the hero), each with its item count and
calories and a button that logs it through the same saved-meal path as Add's product search (which meal, Undo).
Not in pick mode, which already lists saved meals in the product search.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
CAPTURES = ROOT / "ios/HealthNutrition/Tests/ScreenshotCaptureTests.swift"
CARDS = UI / "SavedMealCards.swift"


def test_the_cards_have_their_own_file() -> None:
    assert CARDS.exists(), "NutritionUI/SavedMealCards.swift holds the row"
    text = CARDS.read_text()
    assert re.search(r"struct SavedMealCardRow\s*:\s*View", text)
    assert "ScrollView(.horizontal" in text
    assert "HeroCard" in text and "ContentCard" in text, "the first card is on the hero, the rest are content cards"
    assert re.search(r'accessibilityLabel\(\s*"Log \\\(', text), "each log button names its meal"
    assert '"See all"' not in text, "there is no list screen to open"


def test_the_library_shows_the_row_only_outside_pick_mode() -> None:
    library = (UI / "LibraryView.swift").read_text()
    i = library.find("SavedMealCardRow(")
    assert i >= 0, "the Library shows the row"
    guard = library.rfind("if ", 0, i)
    assert guard >= 0 and i - guard < 300, "the row sits right inside an if"
    assert "onPick == nil" in library[guard:i], "never in pick mode: the if right around the row checks onPick == nil"
    assert i > library.find(".pickerStyle(.segmented)") > 0, "the row sits under the segments"


def test_logging_reuses_the_saved_meal_path() -> None:
    text = CARDS.read_text() + (UI / "LibraryView.swift").read_text()
    assert "SavedMealLogger(" not in text, "log through SavedMealsModel, as the product search does"
    assert re.search(r"savedMeals\??\.log\(|\.logSavedMeal\(|savedMeals\??\.\w*[lL]og\w*\(", text), \
        "the button logs through the saved meals model"
    assert "confirmationDialog(" in text, "it asks which meal, as the product search does"


def test_the_row_has_a_capture() -> None:
    assert re.search(r'capture\(\s*"SavedMealCardRow"', CAPTURES.read_text())
