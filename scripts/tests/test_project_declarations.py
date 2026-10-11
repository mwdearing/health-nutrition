"""The app target declares what App Store Connect otherwise asks about on every upload."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
from typing import cast

import yaml

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "ios/HealthNutrition/project.yml"
RESOLVED = ROOT / "ios/HealthNutrition/HealthNutrition.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
HCAPTCHA_REVISION = "caea076bb9c4141c5d05c5009f894fede409342d"
RXSWIFT_REVISION = "132aea4f236ccadc51590b38af0357a331d51fa2"


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


def test_the_hcaptcha_package_is_pinned_to_the_verified_release_revision() -> None:
    # The tag is checked against its commit so the project does not resolve a moved version tag.
    packages = cast("dict[str, object]", _project()["packages"])
    assert packages["HCaptcha"] == {
        "url": "https://github.com/hCaptcha/HCaptcha-ios-sdk",
        "revision": HCAPTCHA_REVISION,
    }


def test_the_project_workspace_resolution_locks_hcaptcha_and_its_unlinked_rxswift_dependency() -> None:
    resolved = json.loads(RESOLVED.read_text())
    assert resolved["version"] == 2
    assert "originHash" not in resolved
    pins = {pin["identity"]: pin for pin in resolved["pins"]}
    assert set(pins) == {"hcaptcha-ios-sdk", "rxswift"}
    # A revision requirement is recorded as a commit, not as a version-tag claim.
    assert pins["hcaptcha-ios-sdk"]["state"] == {"revision": HCAPTCHA_REVISION}
    assert pins["rxswift"]["state"] == {
        "revision": RXSWIFT_REVISION,
        "version": "6.10.2",
    }


def test_only_the_resolution_file_is_unignored_inside_the_generated_project() -> None:
    def is_ignored(path: Path) -> bool:
        result = subprocess.run(
            ["git", "check-ignore", "--no-index", "-q", str(path.relative_to(ROOT))],
            cwd=ROOT,
            check=False,
        )
        assert result.returncode in (0, 1)
        return result.returncode == 0

    assert not is_ignored(RESOLVED)
    assert is_ignored(ROOT / "ios/HealthNutrition/HealthNutrition.xcodeproj/project.pbxproj")


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
