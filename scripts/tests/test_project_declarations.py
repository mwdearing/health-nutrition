"""The app target declares what App Store Connect otherwise asks about on every upload."""

from __future__ import annotations

from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2] / "ios/HealthNutrition/project.yml"


def test_the_app_declares_that_it_uses_only_exempt_encryption() -> None:
    # The app uses only the system's TLS and data protection, which are exempt. Without this key
    # every uploaded build sits in "Missing Compliance" until a person answers the question by hand.
    text = PROJECT.read_text()
    assert "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO" in text
