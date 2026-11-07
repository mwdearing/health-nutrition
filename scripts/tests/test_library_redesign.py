"""The Library screens in the redesign's style, keeping their lists, segments and search field.

Rows stay List rows (swipe actions and the UI tests' cells depend on them) drawn on the card colour over the page
colour; the segmented control and the "Search on this device" text field stay as they are; the navigation rows get
icon wells.
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


LISTS = ("LibraryView.swift", "SupplementStackView.swift", "MedicationLogView.swift", "RecipeListView.swift",
         "CommunityProductSearchView.swift")
FORMS = ("RecipeDetailView.swift", "RecipeEditorView.swift", "CustomProductEditorView.swift")


def test_lists_and_forms_sit_on_the_page_colour_with_card_rows() -> None:
    for name in LISTS + FORMS:
        text = read(name)
        assert not OLD_CARD.search(text), f"{name} uses the older Card"
        assert ".scrollContentBackground(.hidden)" in text, name
        assert "TokenColors.page" in text, f"{name} should sit on the page colour"
    for name in LISTS:
        assert ".listRowBackground(TokenColors.card)" in read(name), f"{name} rows use the card colour"


def test_the_segments_and_the_search_field_stay() -> None:
    library = read("LibraryView.swift")
    assert ".pickerStyle(.segmented)" in library
    assert ".searchable(" not in library
    for label in ('"Search on this device"', '"Find shared products"', '"Open recipes"', '"Create product"',
                  '"Edit and sharing review"', '"productVerificationStatus"', '"productDeliveryStatus"'):
        assert label in library, label
    assert '"sharedProductSearchField"' in read("CommunityProductSearchView.swift")


def test_the_navigation_rows_have_icon_wells() -> None:
    assert read("LibraryView.swift").count("IconWell(") >= 2
