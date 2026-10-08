"""The Add capsule sits above the tab bar, never on top of it.

A bottom safe-area inset on the tab view itself is laid out against the screen's bottom edge, so it
covers the tab bar. The inset belongs inside each tab's own navigation stack, whose bottom safe area
ends where the tab bar begins.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT_VIEW = Path(__file__).resolve().parents[2] / "ios/HealthNutrition/Sources/RootView.swift"
INSET = re.compile(r"\.safeAreaInset\(edge: \.bottom\) \{\s*addCapsule\s*\}")
TABS = ("AppTab.today", "AppTab.journal", "AppTab.library")


def _tab_view_body() -> str:
    text = ROOT_VIEW.read_text()
    start = text.index("TabView(selection: $selection) {")
    end = text.index(".tag(AppTab.library)", start)
    return text[start:end]


def test_each_content_tab_carries_the_add_capsule_inside_its_navigation_stack() -> None:
    body = _tab_view_body()
    previous = 0
    for tab in TABS[:-1]:
        cut = body.index(f".tag({tab})", previous)
        section = body[previous:cut]
        assert len(INSET.findall(section)) == 1, tab
        assert INSET.search(section).start() < section.rindex(".tabItem"), tab
        previous = cut
    last = body[previous:]
    assert len(INSET.findall(last)) == 1
    assert INSET.search(last).start() < last.rindex(".tabItem")


def test_the_tab_view_itself_carries_no_add_capsule_inset() -> None:
    text = ROOT_VIEW.read_text()
    after_tabs = text[text.index(".tag(AppTab.library)") :]
    assert not INSET.search(after_tabs)
    assert len(INSET.findall(text)) == len(TABS)
