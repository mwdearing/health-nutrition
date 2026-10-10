"""The app's entitlements file keeps the capabilities the app depends on."""
import plistlib
from pathlib import Path

ENTITLEMENTS = Path(__file__).resolve().parents[2] / "ios" / "HealthNutrition" / "HealthNutrition.entitlements"


def _load() -> dict:
    with ENTITLEMENTS.open("rb") as handle:
        return plistlib.load(handle)


def test_healthkit_stays_enabled():
    assert _load().get("com.apple.developer.healthkit") is True


def test_sign_in_with_apple_is_enabled_with_the_default_scope():
    assert _load().get("com.apple.developer.applesignin") == ["Default"]
