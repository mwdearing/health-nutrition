"""The Add action is a separated tab at the end of the system tab bar, and no floating capsule is left on any screen.

The redesign replaces the floating "Add food, drink, or supplement" capsule with a tab in the search role, which iOS 26
draws apart from the other tabs. Choosing it opens Add and leaves the tab that was showing selected; the rule for that is
AddTabSelection, which its own unit test pins. The capsule's bottom inset and the room the screens kept for it are gone.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ROOT_VIEW = ROOT / "ios/HealthNutrition/Sources/RootView.swift"
UI = ROOT / "ios/NutritionCore/Sources/NutritionUI"
TABS = (
    ("Today", "sun.max", "today"),
    ("Diary", "book.closed", "journal"),
    ("Library", "square.grid.2x2", "library"),
    ("Trends", "chart.bar", "trends"),
)


def _tab_headers(text: str) -> list[tuple[int, str]]:
    """Each `Tab(` call up to the brace that opens its content, with its offset."""
    headers = []
    for match in re.finditer(r"\bTab\(", text):
        brace = text.find("{", match.start())
        headers.append((match.start(), text[match.start() : brace]))
    return headers


def _content_tab_offsets(text: str) -> list[int]:
    offsets = []
    for title, symbol, value in TABS:
        pattern = rf'\bTab\("{title}", systemImage: "{re.escape(symbol)}", value: (?:AppTab)?\.{value}\)'
        match = re.search(pattern, text)
        assert match, f"no system Tab for {title}"
        offsets.append(match.start())
    return offsets


def test_the_four_content_tabs_are_system_tabs_in_order() -> None:
    text = ROOT_VIEW.read_text()
    offsets = _content_tab_offsets(text)
    assert offsets == sorted(offsets)
    assert ".tabItem" not in text


def test_add_is_one_separated_tab_after_the_content_tabs() -> None:
    text = ROOT_VIEW.read_text()
    search = [(start, header) for start, header in _tab_headers(text) if "role: .search" in header]
    assert len(search) == 1
    start, _ = search[0]
    assert start > max(_content_tab_offsets(text))
    tab = text[start : start + 600]
    assert "AddIntakeAction.title" in tab
    assert '"plus"' in tab


def test_choosing_add_goes_through_the_selection_rule() -> None:
    text = ROOT_VIEW.read_text()
    assert "AddTabSelection.resolve(" in text
    # A plain binding would let the Add tab become the selected tab.
    assert "TabView(selection: $selection)" not in text


def test_no_floating_capsule_or_clearance_is_left() -> None:
    text = ROOT_VIEW.read_text()
    assert "addCapsule" not in text
    assert "PrimaryCapsule(AddIntakeAction.title" not in text
    for source in [text, *(path.read_text() for path in sorted(UI.glob("*.swift")))]:
        assert "floatingClearance" not in source


def test_add_actions_include_supplements_in_visible_and_accessible_labels() -> None:
    components = (UI / "DesignComponents.swift").read_text()
    assert 'public static let title = "Add food, drink, or supplement"' in components
    text = ROOT_VIEW.read_text()
    for name in ("TodayView.swift", "JournalView.swift"):
        source = (UI / name).read_text()
        assert re.search(r"actionTitle:\s*(?:onAdd == nil \? nil : )?AddIntakeAction.title", source)
    for source in [text, (UI / "TodayView.swift").read_text(), (UI / "JournalView.swift").read_text()]:
        assert not re.search(r'(?:PrimaryCapsule|accessibilityLabel|Tab)\("Add food(?: or drink)?"', source)
        assert '"Add food, drink, or supplement"' not in source
        assert '"Add food or drink"' not in source
        assert '"Add food"' not in source
    checklist = (UI / "FirstDayChecklist.swift").read_text()
    assert '"Log your first food, drink, or supplement"' in checklist
    assert '"Log your first food or drink"' not in checklist


def test_the_trends_tab_hosts_the_trends_screen_and_there_is_no_settings_tab() -> None:
    text = ROOT_VIEW.read_text()
    assert "TrendsView(today: services.today, journal: services.journal)" in text
    # Settings lives behind the gear on every tab, not in the tab bar.
    assert not re.search(r'\bTab\("Settings"', text)
    assert 'Label("Settings", systemImage: "gearshape")' not in text
    assert "SettingsTabRedirect" not in text
