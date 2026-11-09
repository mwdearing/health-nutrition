"""Saved meals from the Log sheet: a "Saved meal" quick action on Add opens a list of the saved meals; a tap logs one
through SavedMealsModel with Add's meal choice (or the which-meal question when Add has none). The tile shows only
when at least one saved meal exists.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
APP = ROOT / "ios/HealthNutrition/Sources"


def test_add_has_a_saved_meal_route() -> None:
    nav = (APP / "AddNavigation.swift").read_text()
    enum = nav[nav.find("enum AddRoute"):]
    enum = enum[: enum.find("\n}")]
    assert re.search(r"case savedMeals\b", enum), "AddRoute has a savedMeals case"
    root = (APP / "RootView.swift").read_text()
    assert re.search(r"case \.savedMeals\s*:", root), "RootView's Add destination handles .savedMeals"
    assert "AddSavedMealsView(" in root, "the route shows AddSavedMealsView"


def test_the_tile_is_optional_and_named() -> None:
    home = (UI / "AddHomeView.swift").read_text()
    assert re.search(r"onSavedMeals:\s*\(\(\)\s*->\s*Void\)\?\s*=\s*nil", home), "AddHomeView takes an optional onSavedMeals"
    assert 'id: "savedMeal"' in home and '"Saved meal"' in home, "a Saved meal quick action"
    assert re.search(r"if let onSavedMeals", home), "the tile shows only when RootView passes onSavedMeals"


def test_the_list_logs_through_the_saved_meals_model() -> None:
    view = UI / "AddSavedMealsView.swift"
    assert view.exists(), "NutritionUI/AddSavedMealsView.swift holds the list"
    text = view.read_text()
    assert re.search(r"struct AddSavedMealsView\s*:\s*View", text)
    assert ".log(" in text and "SavedMealsModel" in text, "logging goes through SavedMealsModel.log"
    assert "SavedMealLogger" not in text, "never the shortcut logger"
    assert "mealChoices(" in text, "with no meal chosen on Add, it asks which meal like the Library cards"


def test_root_passes_the_tile_only_with_saved_meals() -> None:
    root = (APP / "RootView.swift").read_text()
    call = root[root.find("onSavedMeals:"):][:300]
    assert "onSavedMeals:" in root and ("isEmpty" in call or "count" in call), \
        "RootView passes onSavedMeals only when a saved meal exists"


def test_the_unit_tests_exist() -> None:
    tests = (ROOT / "ios/NutritionCore/Tests/NutritionUITests/AddSavedMealsTests.swift").read_text()
    for name in ("testASavedMealLogsWithAddsMealChoice", "testWithNoMealChosenTheMealIsAsked",
                 "testNoSavedMealsMeansNoTile"):
        assert f"func {name}(" in tests, name
