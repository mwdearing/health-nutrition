"""The app's entitlements: HealthKit stays on, and Sign in with Apple is the only addition.

The iOS workflow runs this file, so a change to the entitlements that drops either capability fails
the build before it reaches a signed upload.
"""

from __future__ import annotations

import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENTITLEMENTS = ROOT / "ios/HealthNutrition/HealthNutrition.entitlements"
WORKFLOW = ROOT / ".github/workflows/ios.yml"
APPLE_SIGN_IN = "com.apple.developer.applesignin"
HEALTHKIT = "com.apple.developer.healthkit"


def _entitlements() -> dict[str, object]:
    with ENTITLEMENTS.open("rb") as handle:
        return plistlib.load(handle)


def test_sign_in_with_apple_uses_the_default_scope() -> None:
    assert _entitlements()[APPLE_SIGN_IN] == ["Default"]


def test_healthkit_stays_enabled() -> None:
    assert _entitlements()[HEALTHKIT] is True


def test_no_other_capability_is_declared() -> None:
    assert set(_entitlements()) == {APPLE_SIGN_IN, HEALTHKIT}


def test_the_ios_workflow_runs_this_test_on_every_relevant_change() -> None:
    text = WORKFLOW.read_text()
    path = "scripts/tests/test_entitlements.py"
    # Once in the pull request filter, once in the push filter, and once as a run step.
    assert text.count(path) == 3
    assert "python -m pytest -q -p no:cacheprovider scripts/tests/test_entitlements.py" in text
