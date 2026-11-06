"""Settings and its forms in the redesign's style: the Daily goals row as a hero row, icon tiles on the rows, forms on
the page colour, Welcome's first card on the hero. Every presentation stays on the Settings Form, and every label the
UI tests match stays.
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


FORMS = ("AppSettingsView.swift", "GoalsView.swift", "ConnectionsPrivacyView.swift", "SignInSheet.swift",
         "SharingDisclosureSheet.swift")


def test_settings_keeps_its_form_and_presentations() -> None:
    settings = read("AppSettingsView.swift")
    assert "Form {" in settings
    assert ".accountPresentations(model.account)" in settings
    assert ".listRowBackground(TokenColors.hero)" in settings, "the Daily goals row is the hero row"
    assert settings.count("IconWell(") >= 4
    assert '"Daily goals' in settings


def test_forms_sit_on_the_page_colour() -> None:
    for name in FORMS:
        text = read(name)
        assert not OLD_CARD.search(text), f"{name} uses the older Card"
        assert ".scrollContentBackground(.hidden)" in text, name
        assert "TokenColors.page" in text, f"{name} should sit on the page colour"


def test_welcome_and_goal_setup_use_the_new_cards() -> None:
    welcome = read("WelcomeView.swift")
    assert "HeroCard" in welcome
    assert not OLD_CARD.search(welcome)
    assert '"Get started"' in welcome
    setup = read("GoalSetupView.swift")
    assert not OLD_CARD.search(setup)
    assert '"Help me set my goals"' in read("GoalsView.swift")
