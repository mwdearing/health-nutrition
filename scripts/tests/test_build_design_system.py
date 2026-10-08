"""Tests for scripts/build_design_system.py, on a small synthetic Swift tree."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "build_design_system.py"
spec = importlib.util.spec_from_file_location("build_design_system", SCRIPT)
assert spec and spec.loader
bds = importlib.util.module_from_spec(spec)
sys.modules["build_design_system"] = bds
spec.loader.exec_module(bds)

TODAY = '''
import SwiftUI
public struct TodayView: View {
    public var body: some View {
        List {
            Section("Totals") { Text("Water").font(.body).foregroundStyle(TokenColors.textPrimary) }
            Button { } label: { Text("Add") }
        }
        .navigationTitle("Today")
    }
}
private struct Helper: View { var body: some View { Text("hidden") } }
'''
BADGE = '''
public struct KindTag: View { var body: some View { Text(kind) } }
'''
SCALES = '''
public enum DesignSpacing {
    public static let s: CGFloat = 8
}
public enum DesignRadius {
    public static let card: CGFloat = 22
}
'''


def make_tree(root: Path) -> None:
    ui = root / "ios/NutritionCore/Sources/NutritionUI"
    ui.mkdir(parents=True)
    (ui / "TodayView.swift").write_text(TODAY)
    (ui / "KindTag.swift").write_text(BADGE)
    (ui / "DesignComponents.swift").write_text(SCALES)
    app = root / "ios/HealthNutrition/Sources"
    (app / "Debug").mkdir(parents=True)
    (app / "Debug" / "SpikeView.swift").write_text("struct SpikeView: View { var body: some View { Text(\"x\") } }")


def test_finds_public_views_and_skips_private_and_debug(tmp_path):
    make_tree(tmp_path)
    screens, fonts, _ = bds.scan_screens(tmp_path)
    assert set(screens) == {"TodayView", "KindTag"}
    assert fonts == {"body"}


def test_screen_content_is_extracted(tmp_path):
    make_tree(tmp_path)
    today = bds.scan_screens(tmp_path)[0]["TodayView"]
    kinds = [e[0] for e in today["elements"]]
    assert ("title", "Today") in today["elements"]
    assert ("section", "Totals") in today["elements"]
    assert "text" in kinds
    assert today["colors"] == ["textPrimary"]
    assert today["group"] == "Screens"


def test_small_views_without_page_chrome_are_components(tmp_path):
    make_tree(tmp_path)
    assert bds.scan_screens(tmp_path)[0]["KindTag"]["group"] == "Components"


def test_design_scales_become_spacing_and_radius_tokens(tmp_path):
    make_tree(tmp_path)
    scales = bds.scan_design_scales(tmp_path)
    assert scales == {"Spacing": {"s": "8"}, "Radius": {"card": "22"}}
    tokens = {"c": ("#000000", "#ffffff")}
    result = bds.tokens_json(tokens, "T", {"body"}, {"8", "12"}, scales)
    assert [t["name"] for t in result["spacing"]["tokens"]] == ["space-s", "space-12"]
    assert result["radius"]["tokens"][0] == {"name": "radius-card", "value": "22px", "usage": "DesignRadius.card."}


def test_only_screens_with_both_appearances_count_as_captured(tmp_path):
    shots = tmp_path / "shots"
    shots.mkdir()
    for name in ("TodayView-light.png", "TodayView-dark.png", "JournalView-light.png"):
        (shots / name).write_bytes(b"png")
    assert bds.find_screenshots(shots) == {"TodayView"}
    assert bds.find_screenshots(None) == set()


def test_missing_screenshots_ignores_components_and_camera_sheets():
    screens = {
        "TodayView": {"group": "Screens"},
        "KindTag": {"group": "Components"},
        "BarcodeScannerSheet": {"group": "App"},
        "JournalView": {"group": "Screens"},
    }
    assert bds.missing_screenshots(screens, {"TodayView"}) == ["JournalView"]


def test_preview_uses_the_picture_only_when_both_urls_are_known():
    screen = {"name": "TodayView", "source": "a.swift", "group": "Screens", "elements": [("title", "Today")]}
    blobs = {"TodayView-light.png": "/_blob/aa", "TodayView-dark.png": "/_blob/bb"}
    with_picture = bds.screen_preview(screen, blobs)
    assert '/_blob/aa' in with_picture and '/_blob/bb' in with_picture and 'data-theme="dark"' in with_picture
    outline = bds.screen_preview(screen, {"TodayView-light.png": "/_blob/aa"})
    assert "/_blob/" not in outline and "phone" in outline


def test_check_flag_exits_nonzero_for_an_uncovered_screen(tmp_path):
    # The real repository has screens; an empty screenshots directory leaves them all uncovered.
    shots = tmp_path / "shots"
    shots.mkdir()
    done = subprocess.run(
        [sys.executable, str(SCRIPT), str(tmp_path / "out"), "--check", "--screenshots", str(shots)],
        capture_output=True, text=True, check=False)
    assert done.returncode == 1
    assert "screen with no screenshot" in done.stdout


def test_generated_tokens_json_is_readable_json(tmp_path):
    done = subprocess.run([sys.executable, str(SCRIPT), str(tmp_path), "--no-index"],
                          capture_output=True, text=True, check=False)
    assert done.returncode == 0, done.stderr
    tokens = json.loads((tmp_path / "project/tokens.json").read_text())
    assert len(tokens["color"]["tokens"]) >= 20
