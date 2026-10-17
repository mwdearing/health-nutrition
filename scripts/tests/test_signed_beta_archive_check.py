"""Runs the signed workflow's archive check against a faked archive.

The step reads a built .xcarchive with PlistBuddy, codesign and security, which exist only on macOS, so the
tests stand in for those three tools with small scripts that read plain plist files, and build a fake archive
beside them. What is under test is the step's own shell: which archives it passes, which it fails, and that it
never prints the bundle id.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
from pathlib import Path
from collections.abc import Callable
from typing import cast

import pytest
import yaml

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/signed-beta.yml"
STEP_NAME = "Check the archive embeds the widget and Watch extensions"
BUNDLE = "com.example.hn"
GROUP = f"group.{BUNDLE}"
GROUP_KEY = "com.apple.security.application-groups"
POINT = "com.apple.widgetkit-extension"

PLISTBUDDY = """#!/usr/bin/env python3
import plistlib, sys
cmd, path = sys.argv[2], sys.argv[3]
try:
    cur = plistlib.load(open(path, "rb"))
except Exception:
    print("Error Reading File: " + path); sys.exit(1)
for key in cmd[len("Print :"):].split(":"):
    try:
        cur = cur[int(key)] if isinstance(cur, list) else cur[key]
    except Exception:
        print('Print: Entry, ":%s", Does Not Exist' % key, file=sys.stderr); sys.exit(1)
print(cur)
"""
CODESIGN = """#!/usr/bin/env python3
import os, sys
path = os.path.join(sys.argv[-1], "entitlements.plist")
if not os.path.exists(path):
    sys.exit(1)
sys.stdout.buffer.write(open(path, "rb").read())
"""
SECURITY = """#!/usr/bin/env python3
import sys
sys.stdout.buffer.write(open(sys.argv[-1] + ".decoded", "rb").read())
"""


def _script() -> str:
    raw = cast("dict[str, object]", yaml.safe_load(WORKFLOW.read_text()))
    (job,) = cast("dict[str, dict[str, object]]", raw["jobs"]).values()
    steps = cast("list[dict[str, object]]", job["steps"])
    return str(next(s for s in steps if s.get("name") == STEP_NAME)["run"])


def _bundle(
    path: Path,
    bundle_id: str,
    *,
    extra: dict[str, object] | None = None,
    point: str | None = None,
    groups: list[str] | None = None,
    profile: bool = True,
    build: str = "136",
) -> None:
    path.mkdir(parents=True, exist_ok=True)
    info: dict[str, object] = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": "0.1.30",
        "CFBundleVersion": build,
        "MinimumOSVersion": "18.0",
    }
    info.update(extra or {})
    if point:
        info["NSExtension"] = {"NSExtensionPointIdentifier": point}
    (path / "Info.plist").write_bytes(plistlib.dumps(info))
    held = [GROUP] if groups is None else groups
    (path / "entitlements.plist").write_bytes(plistlib.dumps({GROUP_KEY: held}))
    for leftover in (path / "embedded.mobileprovision", path / "embedded.mobileprovision.decoded"):
        leftover.unlink(missing_ok=True)
    if profile:
        (path / "embedded.mobileprovision").write_bytes(b"x")
        (path / "embedded.mobileprovision.decoded").write_bytes(
            plistlib.dumps({"Entitlements": {GROUP_KEY: held}})
        )


class Archive:
    """A fake archive, its stand-in tools and a project.yml to run the step in."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.temp = root / "temp"
        self.project = root / "project"
        self.bin = root / "bin"
        for directory in (self.temp, self.project, self.bin):
            directory.mkdir()
        for name, body in (("PlistBuddy", PLISTBUDDY), ("codesign", CODESIGN), ("security", SECURITY)):
            tool = self.bin / name
            tool.write_text(body)
            tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        self.app = self.temp / "HealthNutrition.xcarchive/Products/Applications/HealthNutrition.app"
        _bundle(self.app, BUNDLE)
        _bundle(self.app / "PlugIns/HealthNutritionWidgets.appex", f"{BUNDLE}.widgets", point=POINT)
        self.project_yml("targets: {}\n")

    def project_yml(self, text: str) -> None:
        (self.project / "project.yml").write_text(text)

    def add_watch(self, **changes: object) -> None:
        watch = self.app / ("Watch/Renamed.app" if changes.get("renamed") else "Watch/HealthNutritionWatch.app")
        shutil.rmtree(self.app / "Watch", ignore_errors=True)
        app_id, companion, widget_id = f"{BUNDLE}.watchkitapp", BUNDLE, f"{BUNDLE}.watchkitapp.widgets"
        point, groups, widget_profile = POINT, None, True
        if changes.get("bad_id"):
            app_id = f"{BUNDLE}.watch"
        if changes.get("bad_companion"):
            companion = "com.other"
        if changes.get("bad_point"):
            point = "com.apple.widget-extension"
        if changes.get("two_groups"):
            groups = [GROUP, "group.extra"]
        if changes.get("wrong_group"):
            groups = ["group.other"]
        if changes.get("no_widget_profile"):
            widget_profile = False
        if changes.get("bad_widget_id"):
            widget_id = f"{BUNDLE}.watchkitapp.other"
        widget_groups = [GROUP, "group.extra"] if changes.get("widget_two_groups") else None
        if changes.get("widget_wrong_group"):
            widget_groups = ["group.other"]
        _bundle(
            watch,
            app_id,
            extra={"WKCompanionAppBundleIdentifier": companion, **cast("dict[str, object]", changes.get("watch_info", {}))},
            groups=groups,
            profile=not changes.get("no_watch_profile"),
            build=str(changes.get("watch_build", "136")),
        )
        if changes.get("two_apps"):
            shutil.copytree(watch, self.app / "Watch/Second.app")
        if not changes.get("no_widget"):
            _bundle(
                watch / "PlugIns/HealthNutritionWatchWidgets.appex",
                widget_id,
                point=point,
                profile=widget_profile,
                groups=widget_groups,
                build=str(changes.get("widget_build", "136")),
                extra=cast("dict[str, object]", changes.get("widget_info", {})),
            )

    def run(self) -> subprocess.CompletedProcess[str]:
        original = _script()
        script = original.replace("pb=/usr/libexec/PlistBuddy", f"pb={self.bin / 'PlistBuddy'}")
        assert script != original, "the step no longer sets pb= to PlistBuddy; update the stand-in"
        env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "RUNNER_TEMP": str(self.temp),
            "BUNDLE_ID": BUNDLE,
        }
        return subprocess.run(
            ["bash", "-c", script], cwd=self.project, env=env, capture_output=True, text=True, check=False
        )


@pytest.fixture
def archive(tmp_path: Path) -> Archive:
    return Archive(tmp_path)


def _fails(result: subprocess.CompletedProcess[str]) -> list[str]:
    return [line for line in result.stdout.splitlines() if line.startswith("FAIL")]


def test_an_archive_with_a_correct_widget_passes(archive: Archive) -> None:
    result = archive.run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert _fails(result) == []
    assert "this project does not embed a Watch app" in result.stdout


def test_a_missing_widget_extension_fails(archive: Archive) -> None:
    shutil.rmtree(archive.app / "PlugIns")
    result = archive.run()
    assert result.returncode != 0
    assert "FAIL  PlugIns/HealthNutritionWidgets.appex is present" in result.stdout


@pytest.mark.parametrize(
    ("label", "change"),
    [
        ("extension bundle id", lambda a: _bundle(a.app / "PlugIns/HealthNutritionWidgets.appex", f"{BUNDLE}.other", point=POINT)),
        ("extension point", lambda a: _bundle(a.app / "PlugIns/HealthNutritionWidgets.appex", f"{BUNDLE}.widgets", point="com.apple.other")),
        ("a second App Group", lambda a: _bundle(a.app / "PlugIns/HealthNutritionWidgets.appex", f"{BUNDLE}.widgets", point=POINT, groups=[GROUP, "group.extra"])),
        ("a wrong App Group", lambda a: _bundle(a.app / "PlugIns/HealthNutritionWidgets.appex", f"{BUNDLE}.widgets", point=POINT, groups=["group.other"])),
        ("no embedded profile", lambda a: _bundle(a.app / "PlugIns/HealthNutritionWidgets.appex", f"{BUNDLE}.widgets", point=POINT, profile=False)),
        ("a build number that differs", lambda a: _bundle(a.app / "PlugIns/HealthNutritionWidgets.appex", f"{BUNDLE}.widgets", point=POINT, build="99")),
    ],
)
def test_a_wrongly_built_widget_fails(archive: Archive, label: str, change: Callable[[Archive], None]) -> None:
    change(archive)
    result = archive.run()
    assert result.returncode != 0, label
    assert _fails(result), label


def test_no_watch_app_passes_when_the_project_does_not_embed_one(archive: Archive) -> None:
    result = archive.run()
    assert result.returncode == 0
    assert _fails(result) == []
    assert "NOTE  this project does not embed a Watch app" in result.stdout
    assert BUNDLE not in result.stdout + result.stderr


@pytest.mark.parametrize(
    "dependency",
    [
        "      - target: HealthNutritionWatch\n",
        "      - {target: HealthNutritionWatch, embed: true}\n",
        "      - target: HealthNutritionWatch # embedded\n",
    ],
)
def test_a_project_that_embeds_a_watch_app_requires_one_in_the_archive(archive: Archive, dependency: str) -> None:
    archive.project_yml("targets:\n  HealthNutrition:\n    dependencies:\n" + dependency)
    result = archive.run()
    assert result.returncode != 0
    assert "FAIL  the archive has a Watch app, as the project embeds one" in result.stdout


def test_a_renamed_watch_target_still_requires_a_watch_app(archive: Archive) -> None:
    archive.project_yml("targets:\n  Companion:\n    type: application\n    platform: watchOS\n")
    result = archive.run()
    assert result.returncode != 0
    assert "FAIL  the archive has a Watch app, as the project embeds one" in result.stdout


def test_a_missing_project_file_stops_the_step(archive: Archive) -> None:
    (archive.project / "project.yml").unlink()
    result = archive.run()
    assert result.returncode != 0
    assert "project.yml is not where this step expects it" in result.stdout


def test_a_correct_watch_app_passes(archive: Archive) -> None:
    archive.project_yml("      - target: HealthNutritionWatch\n")
    archive.add_watch()
    result = archive.run()
    assert result.returncode == 0, result.stdout
    assert _fails(result) == []


WATCH_CASES = [
    ({"bad_id": True}, "Watch app bundle id is the app's id plus .watchkitapp"),
    ({"bad_companion": True}, "Watch app names the iPhone app as its companion"),
    ({"bad_point": True}, "Watch extension point is com.apple.widgetkit-extension"),
    ({"two_groups": True}, "HealthNutritionWatch.app lists exactly one App Group"),
    ({"wrong_group": True}, "HealthNutritionWatch.app's first App Group is the app's group"),
    ({"no_watch_profile": True}, "HealthNutritionWatch.app has an embedded provisioning profile"),
    ({"no_widget_profile": True}, "HealthNutritionWatchWidgets.appex has an embedded provisioning profile"),
    ({"watch_build": "99"}, "Watch app build number matches the iPhone app"),
    ({"watch_info": {"CFBundleShortVersionString": "9.9.9"}}, "Watch app version matches the iPhone app"),
    ({"widget_build": "99"}, "Watch widget build number matches the iPhone app"),
    ({"widget_info": {"CFBundleShortVersionString": "9.9.9"}}, "Watch widget version matches the iPhone app"),
    ({"bad_widget_id": True}, "Watch widget bundle id is the app's id plus .watchkitapp.widgets"),
    ({"widget_wrong_group": True}, "HealthNutritionWatchWidgets.appex's first App Group is the app's group"),
    ({"widget_two_groups": True}, "HealthNutritionWatchWidgets.appex lists exactly one App Group"),
    ({"no_widget": True}, "the Watch app embeds PlugIns/HealthNutritionWatchWidgets.appex"),
    ({"renamed": True}, "the Watch app is HealthNutritionWatch.app"),
    ({"two_apps": True}, "the archive has exactly one Watch app"),
]


@pytest.mark.parametrize(("change", "label"), WATCH_CASES, ids=[label for _, label in WATCH_CASES])
def test_a_wrongly_built_watch_app_fails_on_exactly_its_check(archive: Archive, change: dict[str, object], label: str) -> None:
    archive.project_yml("      - target: HealthNutritionWatch\n")
    archive.add_watch(**change)
    result = archive.run()
    assert result.returncode != 0
    assert f"FAIL  {label}" in result.stdout


def test_the_output_never_contains_the_bundle_id(archive: Archive) -> None:
    archive.project_yml("      - target: HealthNutritionWatch\n")
    for change in ({}, {"bad_id": True}, {"two_groups": True}, {"wrong_group": True}, {"widget_wrong_group": True}):
        archive.add_watch(**change)
        result = archive.run()
        assert BUNDLE not in result.stdout + result.stderr
