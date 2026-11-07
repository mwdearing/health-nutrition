"""The redesign's finish: every screen has a capture, the older card and the styles nothing uses any more are gone, and
the docs describe the components the app now draws with.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
IOS = ROOT / "ios"
CAPTURES = ROOT / "ios/HealthNutrition/Tests/ScreenshotCaptureTests.swift"
OLD_CARD = re.compile(r"(?<![A-Za-z])Card\s*(?:\{|\()")
RETIRED = ("MacroColumn", "ThinBar", "SummaryTile", "NourishGauge")
COMPONENTS = ("ContentCard", "IconWell", "SectionHeader", "StatTile", "HeroCard", "CalorieRing", "MacroBar")


def swift_sources() -> list[Path]:
    return sorted(IOS.rglob("*.swift"))


def test_the_three_missing_screens_have_a_capture() -> None:
    text = CAPTURES.read_text()
    for name in ("MedicationLogView", "MedicationHistoryView", "HeroCard"):
        assert re.search(rf'capture\(\s*"{name}"', text), f"no capture for {name}"


def test_the_older_card_is_gone() -> None:
    for path in swift_sources():
        text = path.read_text()
        assert not re.search(r"\bstruct Card\s*<", text), f"{path.relative_to(ROOT)} still declares the older Card"
        assert not OLD_CARD.search(text), f"{path.relative_to(ROOT)} still uses the older Card"
    assert "older `Card`" not in (UI / "CardComponents.swift").read_text(), "CardComponents still mentions the older Card"


def test_styles_nothing_uses_are_removed() -> None:
    for path in swift_sources():
        text = path.read_text()
        for name in RETIRED:
            assert not re.search(rf"\b{name}\b", text), f"{path.relative_to(ROOT)} still has {name}"
    assert not (UI / "NourishComponents.swift").exists(), "NourishComponents.swift only held retired styles"


def test_the_design_tokens_doc_lists_the_components() -> None:
    text = (ROOT / "docs/design-tokens.md").read_text()
    assert re.search(r"^## Components$", text, re.MULTILINE), "docs/design-tokens.md has no Components section"
    section = text.split("## Components", 1)[1]
    for name in COMPONENTS:
        assert f"`{name}`" in section, f"the Components section does not name `{name}`"


def test_the_today_doc_says_macro_bars() -> None:
    text = (ROOT / "docs/today-screen.md").read_text()
    assert not re.search(r"macro columns?", text, re.IGNORECASE), "docs/today-screen.md still says macro columns"
