"""Keep public privacy copy aligned with the shipped manifest and current source boundaries."""
from __future__ import annotations

import importlib.util
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "ios/HealthNutrition/Resources/PrivacyInfo.xcprivacy"
PREFERENCES = ROOT / "ios/NutritionCore/Sources/NutritionUI/DisplayPreferences.swift"
VIEW_MODEL = ROOT / "ios/NutritionCore/Sources/NutritionUI/ConnectionsPrivacyViewModel.swift"
APP_SERVICES = ROOT / "ios/HealthNutrition/Sources/AppServices.swift"

_checker_spec = importlib.util.spec_from_file_location(
    "privacy_manifest_checker", ROOT / "scripts/check_privacy_manifest.py"
)
assert _checker_spec and _checker_spec.loader
_checker = importlib.util.module_from_spec(_checker_spec)
_checker_spec.loader.exec_module(_checker)


def _section(document: str, heading: str) -> str:
    start = document.index(heading)
    next_heading = document.find("\n## ", start + len(heading))
    return document[start:] if next_heading < 0 else document[start:next_heading]


def _table_rows(section: str) -> list[list[str]]:
    rows = []
    for line in section.splitlines():
        if line.startswith("|") and "---" not in line:
            rows.append([cell.strip() for cell in line.strip("|").split("|")])
    return rows[1:]


def _manifest() -> dict:
    return plistlib.loads(MANIFEST.read_bytes())


def _reset_preference_keys() -> set[str]:
    source = PREFERENCES.read_text(encoding="utf-8")
    prefix = re.search(r'static let keyPrefix = "([^"]+)"', source)
    assert prefix, "DisplayPreferences key prefix must remain explicit"
    init = source.split("public init(defaults:", 1)[1].split("    }", 1)[0]
    assigned = {
        name: prefix.group(1) + suffix
        for name, suffix in re.findall(r"self\.(\w+) = Self\.keyPrefix \+ \"([^\"]+)\"", init)
    }
    assigned.update(dict(re.findall(r'private let (\w+) = "(display\.[^"]+)"', source)))
    reset = source.split("public func resetToDefaults() {", 1)[1].split("\n    }", 1)[0]
    names = re.findall(r"removeObject\(forKey: (\w+)\)", reset)
    assert len(names) == len(set(names)), "reset should remove each preference key once"
    return {assigned[name] for name in names}


def test_manifest_documentation_matches_actual_declarations_and_checker_scope() -> None:
    manifest = _manifest()
    document = (ROOT / "docs/privacy-manifest.md").read_text(encoding="utf-8")

    collected = manifest["NSPrivacyCollectedDataTypes"]
    actual_types = {row["NSPrivacyCollectedDataType"] for row in collected}
    assert len(actual_types) == 4
    collected_section = _section(document, "## Collected data")
    documented_types = {
        row[0].strip("`") for row in _table_rows(collected_section) if row and row[0].startswith("`")
    }
    assert documented_types == actual_types
    assert re.search(r"four (?:collected-data )?types", collected_section.lower())
    for row in collected:
        assert row["NSPrivacyCollectedDataTypeLinked"] is True
        assert row["NSPrivacyCollectedDataTypeTracking"] is False
        assert row["NSPrivacyCollectedDataTypePurposes"] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]

    accessed = {
        row["NSPrivacyAccessedAPIType"]: set(row["NSPrivacyAccessedAPITypeReasons"])
        for row in manifest["NSPrivacyAccessedAPITypes"]
    }
    assert len(accessed) == 2
    declared_section = _section(document, "## Declared required-reason APIs")
    documented_reasons = {
        row[0].strip("`"): set(re.findall(r"[A-Z0-9]{4}\.\d", row[1]))
        for row in _table_rows(declared_section)
        if len(row) >= 2 and row[0].startswith("`")
    }
    assert documented_reasons == accessed
    assert "two required-reason api categories" in declared_section.lower()

    supported_section = _section(document, "## Categories supported by the checker")
    documented_supported = {row[0].strip("`") for row in _table_rows(supported_section) if row[0].startswith("`")}
    assert documented_supported == set(_checker.CATEGORIES)
    for category, (reason, _, _) in _checker.CATEGORIES.items():
        matching = [row for row in _table_rows(supported_section) if row[0].strip("`") == category]
        assert matching and reason in matching[0][1]
    assert "not declared yet" not in document.lower()


def test_privacy_and_erase_copy_follow_current_source_keys_and_boundaries() -> None:
    privacy = (ROOT / "PRIVACY.md").read_text(encoding="utf-8").lower()
    accounts = (ROOT / "docs/accounts.md").read_text(encoding="utf-8").lower()
    erase = (ROOT / "docs/erase-all-data.md").read_text(encoding="utf-8").lower()
    view_model = VIEW_MODEL.read_text(encoding="utf-8")
    app_services = APP_SERVICES.read_text(encoding="utf-8")

    stores = set(re.findall(r'appendingPathComponent\("([a-z]+\.store)"\)', app_services))
    store_section = _section((ROOT / "docs/erase-all-data.md").read_text(encoding="utf-8"), "## What is erased")
    documented_stores = {
        cell.strip("`").lower()
        for row in _table_rows(store_section)
        for cell in row[:1]
        if cell.startswith("`")
    }
    assert len(stores) == 4
    assert documented_stores == stores

    preference_keys = _reset_preference_keys()
    assert len(preference_keys) == 9
    preference_section = (ROOT / "docs/erase-all-data.md").read_text(encoding="utf-8").lower()
    for key in preference_keys:
        assert key.lower() in preference_section
    assert "local keychain session" in erase
    assert "does not call server sign-out, account deletion or label retraction" in " ".join(erase.split())
    assert "forensic" in erase and "same store containers, which stay open" in " ".join(erase.split())
    assert "export copies outside the app" in erase and "cannot remove it" in erase

    assert "open food facts" in privacy and "community catalog" in privacy
    assert "share labels off" in privacy and "does not disable" in privacy
    assert "hcaptcha" in privacy and "browser" in privacy and "signals" in privacy
    assert "logged-out use sends nothing" not in privacy
    assert "signing into another account does not partition" in accounts
    assert "healthkit and relay settings" not in accounts
    assert "connection settings and export files are stored" not in privacy
    assert "applehealthavailable = false" in view_model.lower()
    assert "healthrelayavailable = false" in view_model.lower()
    assert "@published public var applehealthenabled = false" in view_model.lower()
    assert "@published public var healthrelayenabled = false" in view_model.lower()
    assert "neither connection can be enabled in release builds" in privacy
    assert "not saved as connection settings" in privacy
    assert "reviewed by the catalog owner" in accounts
    assert "community agreement does not verify" in accounts
    assert "five people" not in accounts and "five accounts" not in accounts
    assert "release builds" in privacy and "debug builds" in privacy

    privacy_summary = view_model.split("public static let privacySummary =", 1)[1].split("public static let exportButtonTitle", 1)[0]
    summary_literals = " ".join(re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', privacy_summary))
    summary = summary_literals.lower()
    for phrase in ("stays on this device", "open food facts", "community catalog", "share labels", "hcaptcha"):
        assert phrase in summary
    assert "nothing is uploaded" not in summary
