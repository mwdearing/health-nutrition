"""Add opens as a sheet at the large detent with a grabber instead of a full-screen cover. A swipe down closes it
like Cancel, except while a form on the stack holds typed input: then the swipe is refused and Cancel asks first.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ROOTVIEW = ROOT / "ios/HealthNutrition/Sources/RootView.swift"


def test_add_is_a_large_sheet_with_a_grabber() -> None:
    root = ROOTVIEW.read_text()
    assert ".fullScreenCover(item: $addHome" not in root, "Add is no longer a full-screen cover"
    i = root.find(".sheet(item: $addHome")
    assert i >= 0, "Add is a sheet"
    body = root[i: i + 6000]
    assert ".presentationDetents([.large])" in body
    assert ".presentationDragIndicator(.visible)" in body


def test_a_swipe_down_keeps_typed_input() -> None:
    root = ROOTVIEW.read_text()
    body = root[root.find(".sheet(item: $addHome"):]
    body = body[:6000]
    assert ".interactiveDismissDisabled(" in body, "the swipe is refused while a form holds typed input"
    assert "hasTypedInput" in body
    assert '"Discard this entry?"' in body, "Cancel still asks"
