"""The Log (Add) screens in the redesign's card and form style, with the flow and its labels unchanged.

Add stays a full-screen cover (the shell presents it); the quick actions become icon tiles, recent items sit in content
cards, the forms keep their Form so every field, menu and button the UI tests reach stays where it is.
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


FILES = ("AddHomeView.swift", "AddIntakeView.swift", "QuickAddView.swift", "AddLibraryPicker.swift",
         "LabelCaptureView.swift")
LABELS = {
    "AddHomeView.swift": ('"Type it in"', '"Amounts only"', '"addSearchRow"', '"Search foods"', '"From Library"',
                          '"Create product"'),
    "AddIntakeView.swift": ('"Log entry"', '"Barcode (optional)"', '"Look up barcode"', '"Brand (optional)"'),
    "QuickAddView.swift": ('"Amounts only"', '"Name (optional)"'),
}


def test_no_older_card_is_left_on_the_log_screens() -> None:
    for name in FILES:
        assert not OLD_CARD.search(read(name)), f"{name} still uses the older Card"
    assert not OLD_CARD.search((APP / "AddBarcodeDestination.swift").read_text())


def test_the_quick_actions_are_icon_tiles_and_recents_sit_in_content_cards() -> None:
    home = read("AddHomeView.swift")
    assert "IconWell(" in home
    assert "ContentCard" in home
    assert "TokenColors.surface" not in home


def test_the_forms_stay_forms_and_the_pending_tint_stays() -> None:
    assert "Form {" in read("AddIntakeView.swift")
    assert "Form {" in read("QuickAddView.swift")
    assert "Form {" in read("LabelCaptureView.swift")
    assert read("LabelCaptureView.swift").count(".listRowBackground(") >= 2


def test_add_keeps_its_labels() -> None:
    for name, labels in LABELS.items():
        text = read(name)
        for label in labels:
            assert label in text, f"{name} lost {label}"
