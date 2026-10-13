"""Guardrails for the CI build workflow.

The signed upload archives in Release for a device and keeps its xcodebuild output out of the public
log, so a compile error the optimizer alone raises would otherwise be invisible. The `release-build`
job exists to show that error in ordinary CI: it must stay a Release build for a generic iOS device
with signing disabled, on the same runner image the signed upload uses.
"""

from __future__ import annotations

import shlex
from pathlib import Path
from typing import cast

import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github/workflows"


def _jobs(name: str) -> dict[str, dict[str, object]]:
    raw = cast("dict[object, object]", yaml.safe_load((WORKFLOWS / name).read_text()))
    return cast("dict[str, dict[str, object]]", raw["jobs"])


def _release_build_command() -> list[str]:
    job = _jobs("ios.yml")["release-build"]
    steps = cast("list[dict[str, object]]", job["steps"])
    builds = [str(step["run"]) for step in steps if "xcodebuild" in str(step.get("run", ""))]
    assert len(builds) == 1, builds
    return shlex.split(builds[0])


def test_release_build_compiles_release_for_a_generic_device_without_signing() -> None:
    words = _release_build_command()
    assert words[0] == "xcodebuild" and "build" in words
    assert words[words.index("-configuration") + 1] == "Release"
    assert words[words.index("-destination") + 1] == "generic/platform=iOS"
    assert "CODE_SIGNING_ALLOWED=NO" in words
    assert "CODE_SIGNING_REQUIRED=NO" in words
    assert 'CODE_SIGN_IDENTITY=' in words
    assert "-disableAutomaticPackageResolution" in words


def test_every_ios_project_build_uses_the_committed_swiftpm_resolution() -> None:
    for workflow_name in ("ios.yml", "screenshots.yml"):
        text = (WORKFLOWS / workflow_name).read_text()
        commands = [line for line in text.splitlines() if "xcodebuild" in line and "-project HealthNutrition.xcodeproj" in line]
        assert commands, workflow_name
        assert all("-disableAutomaticPackageResolution" in line for line in commands), (workflow_name, commands)


def test_release_build_uses_the_signed_upload_runner_image() -> None:
    release = _jobs("ios.yml")["release-build"]
    (signed,) = _jobs("signed-beta.yml").values()
    assert release["runs-on"] == signed["runs-on"]
    assert not str(release["runs-on"]).endswith("-latest")


def test_scanner_and_ios_jobs_have_bounded_deadlines() -> None:
    swift = _jobs("swift-lint.yml")["lint"]
    ios = _jobs("ios.yml")
    assert swift["timeout-minutes"] == 10
    assert ios["privacy-manifest"]["timeout-minutes"] == 10
    for name in ("swift-test", "app-build", "release-build", "app-test", "unsigned-ipa"):
        assert ios[name]["timeout-minutes"] == 30


def test_attribution_scanner_tests_run_in_the_unprivileged_swift_workflow() -> None:
    workflow_path = WORKFLOWS / "swift-lint.yml"
    raw = cast("dict[object, object]", yaml.safe_load(workflow_path.read_text()))
    triggers = raw.get(True, raw.get("on"))
    assert isinstance(triggers, dict)
    assert raw["permissions"] == {"contents": "read"}
    pull_request = cast("dict[str, object]", triggers)["pull_request"]
    assert isinstance(pull_request, dict)
    paths = set(cast("list[str]", cast("dict[str, object]", pull_request)["paths"]))
    assert ".github/scripts/attribution_check.py" in paths
    assert ".github/workflows/attribution-check.yml" in paths
    assert "scripts/tests/test_attribution_check.py" in paths
    assert "scripts/tests/test_ios_workflow.py" in paths
    push = cast("dict[str, object]", triggers)["push"]
    assert isinstance(push, dict)
    push_paths = set(cast("list[str]", cast("dict[str, object]", push)["paths"]))
    assert ".github/scripts/attribution_check.py" in push_paths
    assert ".github/workflows/attribution-check.yml" in push_paths
    assert "scripts/tests/test_attribution_check.py" in push_paths
    assert "scripts/tests/test_ios_workflow.py" in push_paths

    assert "pull_request_target" not in triggers
    steps = cast("list[dict[str, object]]", _jobs("swift-lint.yml")["lint"]["steps"])
    test_commands = [str(step.get("run", "")) for step in steps]
    assert any("scripts/tests/test_attribution_check.py" in command for command in test_commands)
    assert any("scripts/tests/test_ios_workflow.py" in command for command in test_commands)


def test_macos_workflows_cancel_superseded_pull_request_runs() -> None:
    # Every push to a PR otherwise queues a full macOS suite for a commit nobody will read.
    for workflow_name in ("ios.yml", "screenshots.yml", "catalog.yml"):
        raw = cast("dict[object, object]", yaml.safe_load((WORKFLOWS / workflow_name).read_text()))
        concurrency = cast("dict[str, str]", raw.get("concurrency"))
        assert concurrency, workflow_name
        assert "github.workflow" in concurrency["group"], workflow_name
        assert "pull_request.number" in concurrency["group"], workflow_name
        # Pushes and manual runs get a unique key, because a pending run is dropped when another enters its group.
        assert "github.run_id" in concurrency["group"], workflow_name
        assert "github.ref" not in concurrency["group"], workflow_name
        # Only pull request runs may be cancelled; pushes to main must all finish.
        assert concurrency["cancel-in-progress"] == "${{ github.event_name == 'pull_request' }}", workflow_name
