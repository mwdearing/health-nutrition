"""Guardrails for the manual signed-upload workflow.

The workflow signs with an App Store Connect API key held in a protected GitHub
Environment. The repository is public, so what keeps the key safe is the shape of
the workflow: it can start only by hand, it needs a reviewer's approval, it never
reads secrets outside its own steps, and it never writes a secret to a log or an
artifact.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import cast

import yaml

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/signed-beta.yml"
SECRET_NAMES = (
    "ASC_KEY_P8",
    "ASC_KEY_ID",
    "ASC_ISSUER_ID",
    "APPLE_TEAM_ID",
    "BUNDLE_ID",
    "SIGNING_CERT_P12_BASE64",
    "SIGNING_CERT_PASSWORD",
)
PINNED_ACTION = re.compile(r"^\s*uses:\s*[^#\s]+@(?P<sha>[0-9a-f]{40})(?:\s+#.*)?$")


def _load() -> dict[str, object]:
    raw = cast("dict[object, object]", yaml.safe_load(WORKFLOW.read_text()))
    # YAML 1.1 reads the bare key `on` as True; give it its real name.
    return {("on" if key is True else str(key)): value for key, value in raw.items()}


def _jobs() -> dict[str, dict[str, object]]:
    return cast("dict[str, dict[str, object]]", _load()["jobs"])


def _steps() -> list[dict[str, object]]:
    (job,) = _jobs().values()
    return cast("list[dict[str, object]]", job["steps"])


def test_it_starts_only_by_hand() -> None:
    triggers = _load()["on"]
    assert isinstance(triggers, dict)
    assert set(cast("dict[str, object]", triggers)) == {"workflow_dispatch"}


def test_it_runs_in_the_protected_environment_with_read_only_permissions() -> None:
    (job,) = _jobs().values()
    assert job["environment"] == "testflight"
    assert _load()["permissions"] == {"contents": "read"}
    assert "permissions" not in job or job["permissions"] == {"contents": "read"}


def test_it_runs_on_a_hosted_macos_runner_and_pins_every_action() -> None:
    (job,) = _jobs().values()
    assert str(job["runs-on"]).startswith("macos-")
    text = WORKFLOW.read_text()
    uses_lines = [line for line in text.splitlines() if "uses:" in line]
    assert uses_lines
    assert all(PINNED_ACTION.match(line) for line in uses_lines)
    checkout = next(s for s in _steps() if "actions/checkout" in str(s.get("uses")))
    assert cast("dict[str, object]", checkout["with"])["persist-credentials"] is False


def test_secrets_are_read_only_through_step_environments() -> None:
    text = WORKFLOW.read_text()
    for name in SECRET_NAMES:
        assert f"secrets.{name}" in text
        for line in text.splitlines():
            if f"secrets.{name}" in line:
                assert re.match(
                    rf"^\s+{name}: \$\{{\{{ secrets\.{name} \}}\}}\s*$", line
                )
    for step in _steps():
        run = str(step.get("run", ""))
        assert "secrets." not in run
        references = cast("list[str]", re.findall(r"\$\{\{(.*?)\}\}", run))
        assert all(reference.strip().startswith("github.") for reference in references)


def test_no_step_prints_or_uploads_a_secret() -> None:
    text = WORKFLOW.read_text()
    assert "set -x" not in text
    assert "actions/upload-artifact" not in text
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("echo ", "printf ", "cat ")) and "$ASC_KEY_P8" in line:
            assert ">" in line  # only ever redirected into the key file
    for name in SECRET_NAMES:
        assert not re.search(
            rf"echo[^\n]*\$\{{?{name}\}}?(?!\w)[^\n>|]*$", text, re.MULTILINE
        )


def test_the_key_file_is_private_and_always_removed() -> None:
    steps = _steps()
    write_step = next(s for s in steps if "ASC_KEY_P8" in str(s.get("env", {})))
    run = str(write_step["run"])
    assert "umask 077" in run
    cleanup = steps[-1]
    assert cleanup.get("if") == "${{ always() }}"
    assert "rm -f" in str(cleanup["run"])


def test_it_checks_the_secret_formats_without_printing_them() -> None:
    check = next(s for s in _steps() if "Check the signing secrets" in str(s["name"]))
    run = str(check["run"])
    assert "BEGIN PRIVATE KEY" in run
    assert "{10}" in run  # Team ID and Key ID are ten characters
    assert "[0-9a-fA-F]{8}-" in run  # the Issuer ID is a UUID
    assert "echo" not in run.replace('echo "::error::', "")


def test_the_dispatch_inputs_are_validated_before_they_reach_the_build() -> None:
    check = next(s for s in _steps() if "Check the signing secrets" in str(s["name"]))
    env = cast("dict[str, str]", check["env"])
    assert env["BUNDLE_ID"] == "${{ secrets.BUNDLE_ID }}"
    assert env["MARKETING_VERSION"] == "${{ inputs.marketing_version }}"
    run = str(check["run"])
    assert r"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$" in run
    assert r"^[0-9]+\.[0-9]+\.[0-9]+$" in run  # Apple requires three components


def test_it_generates_the_project_before_signing() -> None:
    names = [str(step.get("name", "")) for step in _steps()]
    install = next(name for name in names if name.startswith("Install XcodeGen"))
    assert names.index("Generate the Xcode project") < names.index(
        "Check the signing secrets and write the key file"
    )
    assert names.index(install) < names.index("Generate the Xcode project")


def test_xcodegen_is_a_pinned_release_verified_by_checksum() -> None:
    text = WORKFLOW.read_text()
    assert "brew install" not in text
    assert "mint " not in text
    install = next(s for s in _steps() if str(s["name"]).startswith("Install XcodeGen"))
    env = cast("dict[str, str]", install["env"])
    assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", env["XCODEGEN_VERSION"])
    assert re.fullmatch(r"[0-9a-f]{64}", env["XCODEGEN_SHA256"])
    run = str(install["run"])
    assert "releases/download/$XCODEGEN_VERSION/xcodegen.zip" in run
    assert "shasum -a 256 -c -" in run
    assert run.index("shasum") < run.index("unzip")
    generate = next(s for s in _steps() if s["name"] == "Generate the Xcode project")
    assert "xcodegen-dist/xcodegen/bin/xcodegen" in str(generate["run"])


def test_it_signs_with_the_api_key_and_uploads_directly() -> None:
    text = WORKFLOW.read_text()
    for needle in (
        "xcodebuild archive",
        "-project HealthNutrition.xcodeproj",
        "-scheme HealthNutrition",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        "-authenticationKeyID",
        "-authenticationKeyIssuerID",
        "-exportArchive",
        "<key>destination</key>",
        "<string>upload</string>",
        "<key>method</key>",
        "app-store-connect",
        "<key>testFlightInternalTestingOnly</key>\n            <false/>",
        "CURRENT_PROJECT_VERSION=$BUILD_NUMBER",
        "BUILD_NUMBER=$((GITHUB_RUN_NUMBER + 100))",
    ):
        assert needle in text
    assert "CODE_SIGNING_ALLOWED=NO" not in text


def test_the_bundle_id_is_a_secret_not_an_input_and_no_identity_is_in_the_file() -> (
    None
):
    text = WORKFLOW.read_text()
    inputs = cast(
        "dict[str, object]",
        cast("dict[str, object]", _load()["on"])["workflow_dispatch"],
    )
    assert set(cast("dict[str, object]", inputs["inputs"])) == {"marketing_version"}
    assert "inputs.bundle_id" not in text
    assert "com.mwdearing" not in text
    assert "dev.example" not in text  # the placeholder never reaches a signed build
    assert not re.search(
        r"\b[A-Z0-9]{10}\b(?<![A-Z]{10})", re.sub(r"[A-Z_]{3,}", "", text)
    )


def test_it_runs_only_from_main() -> None:
    (job,) = _jobs().values()
    condition = str(job["if"])
    assert "github.ref == 'refs/heads/main'" in condition
    assert "github.event_name == 'workflow_dispatch'" in condition


def test_xcodebuild_output_stays_out_of_the_public_log() -> None:
    text = WORKFLOW.read_text()
    assert 'quiet Archive "$RUNNER_TEMP/archive.log" xcodebuild archive' in text
    assert 'quiet Export "$RUNNER_TEMP/export.log" xcodebuild -exportArchive' in text
    # The build log file is read only by `errors`, whose output goes to a quiet grep and nowhere else.
    for line in text.splitlines():
        stripped = line.strip()
        if "$log" in stripped and not stripped.startswith(("local ", "if ")):
            assert stripped.startswith("errors() {") or '> "$log"' in stripped
        if stripped.startswith("errors |"):
            assert re.match(
                r"^errors \| grep -qiE .* && echo \"::error::  category: ", stripped
            )
    assert "errors\n" not in text and "errors;" not in text
    assert "tail " not in text
    assert "sed -E" not in text
    assert "category:" in text
    cleanup = _steps()[-1]
    assert "archive.log" in str(cleanup["run"])
    assert "export.log" in str(cleanup["run"])


def test_the_failure_categories_search_only_error_lines() -> None:
    text = WORKFLOW.read_text()
    assert "grep -iE '(^|: )error: |\\*\\* .* FAILED' \"$log\"" in text


def test_the_default_marketing_version_is_the_recorded_one() -> None:
    text = WORKFLOW.read_text()
    assert "project.yml" in text
    assert "MARKETING_VERSION:" in text
    assert "0.1.$GITHUB_RUN_NUMBER" not in text


IMPORT_STEP = "Import the stored signing certificate into a temporary keychain"


def _import_step() -> dict[str, object]:
    return next(s for s in _steps() if str(s.get("name")) == IMPORT_STEP)


def test_the_stored_certificate_is_imported_before_the_archive() -> None:
    # A fresh runner has no signing identity, so automatic signing would create a new development
    # certificate on every run until the team reaches Apple's limit. One stored certificate, imported
    # into a keychain that lives only for the run, is reused instead.
    names = [str(step.get("name", "")) for step in _steps()]
    assert names.index("Check the signing secrets and write the key file") < names.index(IMPORT_STEP)
    assert names.index(IMPORT_STEP) < names.index("Archive with automatic signing")
    step = _import_step()
    assert set(cast("dict[str, str]", step["env"])) == {"SIGNING_CERT_P12_BASE64", "SIGNING_CERT_PASSWORD"}
    run = str(step["run"])
    assert "umask 077" in run
    assert "security create-keychain" in run
    assert "security import" in run
    assert "security set-key-partition-list" in run
    assert "security list-keychains -d user -s" in run
    assert "find-identity -v -p codesigning" in run


def test_the_keychain_password_is_made_per_run_and_is_not_a_secret() -> None:
    run = str(_import_step()["run"])
    assert "KEYCHAIN_PASSWORD=$(openssl rand -hex" in run
    assert "secrets.KEYCHAIN_PASSWORD" not in WORKFLOW.read_text()


def test_the_import_never_prints_the_certificate_or_its_password() -> None:
    run = str(_import_step()["run"])
    assert "echo" not in run.replace('echo "::error::', "")
    for line in run.splitlines():
        stripped = line.strip()
        if "SIGNING_CERT_P12_BASE64" in stripped and stripped.startswith("printf"):
            assert "| base64 --decode >" in stripped  # only ever decoded into the private file
        if stripped.startswith("security "):
            # Nothing a security command says reaches the public log.
            assert "> /dev/null" in stripped or "| grep -q" in stripped or "$(" in stripped


def test_the_temporary_keychain_and_certificate_file_are_always_removed() -> None:
    cleanup = _steps()[-1]
    assert cleanup.get("if") == "${{ always() }}"
    run = str(cleanup["run"])
    assert "security delete-keychain" in run
    assert "signing.keychain-db" in run
    assert "signing.p12" in run
    assert "AuthKey.p8" in run
