"""The widgets and the Watch app take the redesign's colours from their own asset catalogs, kept equal to the tokens.

They do not link NutritionCore, so TokenColors is out of reach; each target gets colour sets named after the tokens
(hero, heroText, RelayMint, macroProtein ...). Every set must match its token in light and dark, every colour a view asks
for must exist in the catalog of the target that compiles it, and no view carries a colour literal.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "ios/HealthNutrition"
TOKENS = ROOT / "ios/NutritionCore/Sources/NutritionCore/NutritionTokens.swift"
CATALOGS = {
    "Widgets": APP / "Widgets/Assets.xcassets",
    "Watch": APP / "Watch/Assets.xcassets",
    "WatchWidgets": APP / "WatchWidgets/Assets.xcassets",
}
REQUIRED = {
    "Widgets": {"hero", "heroText", "heroSecondaryText", "heroTrack", "RelayMint", "macroProtein", "macroCarbs",
                "macroFat"},
    "Watch": {"heroTrack", "RelayMint", "macroProtein", "macroCarbs", "macroFat"},
}
COLOR_USE = re.compile(r'Color\("([^"]+)"\)')
LITERAL = re.compile(r"Color\(\s*(?:red:|\.sRGB|hue:|white:|#)|#[0-9A-Fa-f]{6}\b|UIColor\(")


def _tokens() -> dict[str, tuple[str, str]]:
    found = re.findall(r'Token\(name: "(\w+)", light: "(#[0-9A-Fa-f]{6})", dark: "(#[0-9A-Fa-f]{6})"\)',
                       TOKENS.read_text())
    return {name: (light.upper(), dark.upper()) for name, light, dark in found}


def _channel(text: str) -> str:
    text = str(text).strip()
    if text.lower().startswith("0x"):
        number = int(text, 16)
    elif "." in text:
        number = round(float(text) * 255)
    else:
        number = int(text)
    return f"{number:02X}"


def _colorset(path: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    for entry in json.loads((path / "Contents.json").read_text())["colors"]:
        components = entry["color"]["components"]
        value = "#" + "".join(_channel(components[k]) for k in ("red", "green", "blue"))
        dark = any(a.get("value") == "dark" for a in entry.get("appearances", []))
        found["dark" if dark else "light"] = value
    found.setdefault("dark", found.get("light", ""))
    return found


def _sets(catalog: Path) -> dict[str, Path]:
    return {p.name.removesuffix(".colorset"): p for p in catalog.glob("*.colorset")} if catalog.exists() else {}


def test_every_widget_and_watch_colour_set_equals_its_token() -> None:
    tokens = _tokens()
    seen = 0
    for target, catalog in CATALOGS.items():
        for name, path in _sets(catalog).items():
            seen += 1
            assert name in tokens, f"{target}: colour set {name} is not named after a token"
            light, dark = tokens[name]
            assert _colorset(path) == {"light": light, "dark": dark}, f"{target}: {name} differs from its token"
    assert seen, "no colour sets in the widget and Watch catalogs"


def test_the_colours_each_target_needs_are_in_its_catalog() -> None:
    for target, names in REQUIRED.items():
        missing = names - set(_sets(CATALOGS[target]))
        assert not missing, f"{target} catalog lacks {sorted(missing)}"


def test_every_colour_a_view_asks_for_exists_in_its_target() -> None:
    shared = list((APP / "Shared").glob("*.swift"))
    for source in shared:
        assert not COLOR_USE.search(source.read_text()), f"{source.name} is compiled into every target: no Color(\"...\")"
    for target, catalog in CATALOGS.items():
        names = set(_sets(catalog))
        for source in (APP / target).glob("*.swift"):
            for used in COLOR_USE.findall(source.read_text()):
                assert used in names, f"{source.name} uses Color(\"{used}\"), missing from the {target} catalog"


def test_no_widget_or_watch_view_has_a_colour_literal() -> None:
    for folder in ("Widgets", "Watch", "WatchWidgets", "Shared"):
        for source in (APP / folder).glob("*.swift"):
            match = LITERAL.search(source.read_text())
            assert not match, f"{source.name} has a colour literal {match.group(0)!r}"


def test_the_home_screen_widgets_sit_on_the_hero_and_the_watch_draws_a_ring() -> None:
    widget = (APP / "Widgets/TodayWidget.swift").read_text()
    assert re.search(r'containerBackground\(\s*Color\("hero"\)', widget)
    assert 'Color("heroText")' in widget
    watch = (APP / "Watch/HealthNutritionWatchApp.swift").read_text()
    assert "Gauge(" in watch or ".trim(" in watch
    for macro in ("macroProtein", "macroCarbs", "macroFat"):
        assert f'Color("{macro}")' in watch
