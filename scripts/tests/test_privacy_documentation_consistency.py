"""Keep public privacy copy aligned with the shipped manifest and current source boundaries."""
from __future__ import annotations

import importlib.util
import plistlib
import re
import shutil
from pathlib import Path

import pytest

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


def _submit_label_bodies() -> list[str]:
    definition = re.compile(
        r"\bcreate\s+(?:or\s+replace\s+)?function\s+public\.submit_label\b"
        r"\s*\(([^)]*)\)\s*returns\s+text\b.*?\bas\s+\$\$(.*?)\$\$\s*;",
        re.IGNORECASE | re.DOTALL,
    )
    bodies = []
    for migration in sorted((ROOT / "supabase/migrations").glob("*.sql")):
        for match in definition.finditer(migration.read_text(encoding="utf-8")):
            parameters = tuple(
                (name.lower(), kind.lower())
                for name, kind in re.findall(r"\b(p_\w+)\s+(text|jsonb)\b", match.group(1))
            )
            if parameters == (
                ("p_barcode", "text"),
                ("p_basis", "text"),
                ("p_serving_text", "text"),
                ("p_product_name", "text"),
                ("p_brand", "text"),
                ("p_nutrients", "jsonb"),
            ):
                bodies.append(match.group(2))
    assert bodies, "migrations must define the six-argument public.submit_label used by the app"
    return [body.lower() for body in bodies]


def _latest_submit_label_body() -> str:
    return _submit_label_bodies()[-1]


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
    assert len(preference_keys) == 12
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
    assert "off until you tap connect apple health" in privacy
    assert "not saved as a connection setting" in privacy
    assert "reviewed by the catalog owner" in accounts
    assert "community agreement does not verify" in accounts
    assert "five people" not in accounts and "five accounts" not in accounts
    assert "debug build" in privacy and "never reads other health data" in privacy and "steps, active energy and weight" in privacy

    privacy_summary = view_model.split("public static let privacySummary =", 1)[1].split("public static let exportButtonTitle", 1)[0]
    summary_literals = " ".join(re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', privacy_summary))
    summary = summary_literals.lower()
    for phrase in ("stays on this device", "open food facts", "community catalog", "share labels", "hcaptcha"):
        assert phrase in summary
    assert "nothing is uploaded" not in summary


def test_privacy_documentation_checks_run_for_docs_and_behavior_changes() -> None:
    import yaml

    workflow = yaml.safe_load((ROOT / ".github/workflows/ios.yml").read_text())
    triggers = workflow.get("on", workflow.get(True))
    watched = {
        "PRIVACY.md", "docs/accounts.md", "docs/erase-all-data.md",
        "docs/privacy-manifest.md", "docs/journal-export.md",
        "scripts/tests/test_privacy_documentation_consistency.py",
        "scripts/tests/test_journal_restore_import_race.py",
        "supabase/migrations/**",
    }
    for event in ("pull_request", "push"):
        assert watched <= set(triggers[event]["paths"])
    commands = "\n".join(step.get("run", "") for step in workflow["jobs"]["privacy-manifest"]["steps"])
    assert "scripts/tests/test_privacy_documentation_consistency.py" in commands
    assert "scripts/tests/test_journal_restore_import_race.py" in commands


def test_public_privacy_copy_discloses_apple_health_delivery_and_conditional_camera_check() -> None:
    privacy = (ROOT / "PRIVACY.md").read_text(encoding="utf-8").lower()
    accounts = (ROOT / "docs/accounts.md").read_text(encoding="utf-8").lower()
    erase = (ROOT / "docs/erase-all-data.md").read_text(encoding="utf-8").lower()
    manifest_docs = (ROOT / "docs/privacy-manifest.md").read_text(encoding="utf-8").lower()
    view_model = VIEW_MODEL.read_text(encoding="utf-8").lower()
    app_services = APP_SERVICES.read_text(encoding="utf-8")
    root_view = (ROOT / "ios/HealthNutrition/Sources/RootView.swift").read_text(encoding="utf-8")
    project = (ROOT / "ios/HealthNutrition/project.yml").read_text(encoding="utf-8").lower()
    driver = (ROOT / "ios/HealthNutrition/Sources/HealthKitDeliveryStatus.swift").read_text(encoding="utf-8")

    destination_setup = app_services.split("// Which destinations the journal queues work for.", 1)[1].split(
        "        } catch {", 1
    )[0]
    # Every build queues HealthKit work and none queues relay work; the person's Connect gates writing.
    assert "#if DEBUG" not in destination_setup
    assert "enabledDestinations: [.healthKit]" in destination_setup
    assert ".relay" not in destination_setup.split("enabledDestinations:", 1)[1]
    assert "deliverToHealthKit(now: now)" in root_view
    assert "#if DEBUG\n        deliverToHealthKit" not in root_view
    # Write access only; the request names no read types.
    assert "requestAuthorization(toShare: mapped.share, read: [])" in driver
    assert "connect apple health" in project and "entries you log" in project and "nutrients" in project
    assert "steps, active energy and weight" in project
    assert "no release build writes" not in project
    assert "rare camera check when you ask for an emailed sign-in code" in project

    for document in (privacy, erase, manifest_docs):
        assert "connect" in document and "apple health" in document
        assert "real logged food and water entries" in document
        assert "nutrients" in document and "healthkit" in document
        assert "test samples" in document
        assert "release builds do not" not in document and "cannot enable healthkit" not in document
    for document in (privacy, erase):
        assert "already written" in document
        assert "does not remove" in document or "does not retract" in document
    assert "never reads other health data" in privacy and "steps, active energy and weight" in privacy
    for document in (privacy, accounts):
        assert "rare cases the challenge may request camera access" in document

    summary = view_model.split("public static let privacysummary =", 1)[1].split(
        "public static let exportbuttontitle", 1
    )[0]
    assert "connect apple health" in summary and "healthkit" in summary and "only its own samples" in summary
    assert "camera access" in summary and "email sign-in" in summary


def test_label_submission_copy_discloses_signed_in_account_linkage() -> None:
    accounts = (ROOT / "docs/accounts.md").read_text(encoding="utf-8").lower()
    privacy = (ROOT / "PRIVACY.md").read_text(encoding="utf-8").lower()
    view_model = VIEW_MODEL.read_text(encoding="utf-8").lower()
    client = (ROOT / "ios/NutritionCore/Sources/NutritionProviders/Community/CommunityClient.swift").read_text(
        encoding="utf-8"
    )
    sql = _latest_submit_label_body()

    submit = client.split("public func submitLabel", 1)[1].split("public func", 1)[0]
    assert "authenticatedSend" in submit
    # Either the function itself records the submission under the caller's account id, or (after the
    # legacy bridge) it requires a signed-in, non-anonymous account and delegates to the renamed earlier
    # submit, which still records the submission under that account's id.
    direct = (
        "device uuid := auth.uid()" in sql
        and "insert into catalog.submissions as s (device_id" in sql
    )
    # The delegated implementation is the six-argument definition the bridge replaced, not any text that
    # happens to appear somewhere in the migrations.
    previous = _submit_label_bodies()[:-1]
    delegated = previous[-1] if previous else ""
    bridged = (
        "catalog_v2.live_legacy_account()" in sql
        and "catalog_v2.legacy_submit(" in sql
        and "device uuid := auth.uid()" in delegated
        and "insert into catalog.submissions as s (device_id" in delegated
    )
    assert direct or bridged

    editor = (ROOT / "ios/NutritionCore/Sources/NutritionUI/CustomProductEditorViewModel.swift").read_text(
        encoding="utf-8"
    )
    publish = client.split("public func publish", 1)[1].split("public func", 1)[0]
    assert "expectedownerid" in publish.lower() and "publish" in editor
    assert "p_query" in client
    for document in (accounts, privacy):
        assert "linked to your signed-in account" in document
        assert "journal entries" in document and "photo" in document
        assert "words you typed" in document and "custom product" in document
        assert "withdrawn record" in document
        assert "account identifier" not in document or "is linked" in document
    summary = view_model.split("public static let privacysummary =", 1)[1].split(
        "public static let exportbuttontitle", 1
    )[0]
    assert "linked to your signed-in account" in summary
    assert "journal entries" in summary and "photo" in summary


def test_label_submission_copy_guard_checks_latest_migration_override(tmp_path: Path, monkeypatch) -> None:
    fixture_root = tmp_path / "repo"
    for relative in (
        "PRIVACY.md",
        "docs/accounts.md",
        "ios/NutritionCore/Sources/NutritionProviders/Community/CommunityClient.swift",
        "ios/NutritionCore/Sources/NutritionUI/CustomProductEditorViewModel.swift",
    ):
        destination = fixture_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, destination)

    migrations = fixture_root / "supabase/migrations"
    migrations.mkdir(parents=True)
    shutil.copyfile(
        ROOT / "supabase/migrations/20261011203625_catalog_owner_verification.sql",
        migrations / "20261011203625_catalog_owner_verification.sql",
    )
    (migrations / "20261012235959_submit_label_overload.sql").write_text(
        """create or replace function public.submit_label(p_payload jsonb)
returns uuid
language plpgsql
security definer
as $$
begin
    insert into catalog.submissions (payload) values (p_payload);
    return gen_random_uuid();
end;
$$;
""",
        encoding="utf-8",
    )

    monkeypatch.setattr(__import__(__name__), "ROOT", fixture_root)
    test_label_submission_copy_discloses_signed_in_account_linkage()

    with (migrations / "20261012235959_submit_label_overload.sql").open("a", encoding="utf-8") as migration:
        migration.write(
            """create or replace function public.submit_label(
    p_barcode text, p_basis text, p_serving_text text, p_product_name text, p_brand text, p_nutrients jsonb
) returns text
language plpgsql
security definer
as $$
begin
    insert into catalog.submissions (payload) values (p_nutrients);
    return gen_random_uuid()::text;
end;
$$;
"""
        )
    with pytest.raises(AssertionError):
        test_label_submission_copy_discloses_signed_in_account_linkage()
