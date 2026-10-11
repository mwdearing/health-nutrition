"""The app target declares what App Store Connect otherwise asks about on every upload."""

from __future__ import annotations

from pathlib import Path
from typing import cast

import yaml

PROJECT = Path(__file__).resolve().parents[2] / "ios/HealthNutrition/project.yml"


def test_the_app_declares_that_it_uses_only_exempt_encryption() -> None:
    # The app uses only the system's TLS and data protection, which are exempt. Without this key
    # every uploaded build sits in "Missing Compliance" until a person answers the question by hand.
    text = PROJECT.read_text()
    assert "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO" in text


def _project() -> dict[str, object]:
    return cast("dict[str, object]", yaml.safe_load(PROJECT.read_text()))


def _target(name: str) -> dict[str, object]:
    targets = cast("dict[str, dict[str, object]]", _project()["targets"])
    return targets[name]


def test_the_hcaptcha_package_is_pinned_to_an_exact_version() -> None:
    # A challenge SDK update changes what the sign-in screen shows, so the version is chosen, not floated.
    packages = cast("dict[str, object]", _project()["packages"])
    assert packages["HCaptcha"] == {
        "url": "https://github.com/hCaptcha/HCaptcha-ios-sdk",
        "exactVersion": "3.1.0",
    }


def test_only_the_app_target_links_the_hcaptcha_product() -> None:
    app_dependencies = cast("list[dict[str, str]]", _target("HealthNutrition")["dependencies"])
    assert {"package": "HCaptcha", "product": "HCaptcha"} in app_dependencies
    targets = cast("dict[str, dict[str, object]]", _project()["targets"])
    for name, target in targets.items():
        if name == "HealthNutrition":
            continue
        dependencies = cast("list[dict[str, str]]", target.get("dependencies", []))
        assert not any(dependency.get("package") == "HCaptcha" for dependency in dependencies), name


def test_the_site_key_is_an_empty_build_setting_read_from_the_bundle() -> None:
    # Empty in the repository, so a build without a key shows no challenge. The workflow passes the real value.
    app = _target("HealthNutrition")
    settings = cast("dict[str, dict[str, object]]", app["settings"])
    assert settings["base"]["HCAPTCHA_SITE_KEY"] == ""
    info = cast("dict[str, dict[str, object]]", app["info"])
    assert info["properties"]["HCAPTCHA_SITE_KEY"] == "$(HCAPTCHA_SITE_KEY)"
