"""The app's entitlements: HealthKit stays on, Sign in with Apple and the widgets' App Group are the only others.

The iOS workflow runs this file, so a change to the entitlements that drops either capability fails
the build before it reaches a signed upload.
"""

from __future__ import annotations

import plistlib
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
ENTITLEMENTS = ROOT / "ios/HealthNutrition/HealthNutrition.entitlements"
WORKFLOW = ROOT / ".github/workflows/ios.yml"
APPLE_SIGN_IN = "com.apple.developer.applesignin"
HEALTHKIT = "com.apple.developer.healthkit"
APP_GROUPS = "com.apple.security.application-groups"
WIDGET_ENTITLEMENTS = ROOT / "ios/HealthNutrition/Widgets/HealthNutritionWidgets.entitlements"
GROUP = "group.$(APP_BUNDLE_ID)"


def _entitlements() -> dict[str, object]:
    with ENTITLEMENTS.open("rb") as handle:
        return plistlib.load(handle)


def test_sign_in_with_apple_uses_the_default_scope() -> None:
    assert _entitlements()[APPLE_SIGN_IN] == ["Default"]


def test_healthkit_stays_enabled() -> None:
    assert _entitlements()[HEALTHKIT] is True


def test_no_other_capability_is_declared() -> None:
    assert set(_entitlements()) == {APPLE_SIGN_IN, HEALTHKIT, APP_GROUPS}


def test_the_app_group_is_named_after_the_app_bundle_identifier_in_the_app_and_the_widgets() -> None:
    # The signed-beta workflow sets APP_BUNDLE_ID, so the group follows whichever identifier is signed.
    assert _entitlements()[APP_GROUPS] == [GROUP]
    with WIDGET_ENTITLEMENTS.open("rb") as handle:
        widgets = plistlib.load(handle)
    assert widgets == {APP_GROUPS: [GROUP]}


def test_project_generation_preserves_account_and_health_capabilities() -> None:
    # XcodeGen writes these properties over the plist; a path alone produces an empty file.
    project = yaml.safe_load((ROOT / "ios/HealthNutrition/project.yml").read_text())
    declaration = project["targets"]["HealthNutrition"]["entitlements"]
    assert declaration.get("properties", {}) == {
        APPLE_SIGN_IN: ["Default"], HEALTHKIT: True, APP_GROUPS: [GROUP],
    }
    widgets = project["targets"]["HealthNutritionWidgets"]["entitlements"]
    assert widgets.get("properties", {}) == {APP_GROUPS: [GROUP]}


def test_the_ios_workflow_runs_this_test_on_every_relevant_change() -> None:
    text = WORKFLOW.read_text()
    path = "scripts/tests/test_entitlements.py"
    # Once in the pull request filter, once in the push filter, and once as a run step.
    assert text.count(path) == 3
    assert "python -m pytest -q -p no:cacheprovider scripts/tests/test_entitlements.py" in text
