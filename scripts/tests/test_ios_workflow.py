"""Guardrails for the CI build workflow.

The signed upload archives in Release for a device and keeps its xcodebuild output out of the public
log, so a compile error the optimizer alone raises would otherwise be invisible. The `release-build`
job exists to show that error in ordinary CI: it must stay a Release build for a generic iOS device
with signing disabled, on the same runner image the signed upload uses.
"""

from __future__ import annotations

import re
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
    for name in ("release-build", "unsigned-ipa"):
        assert ios[name]["timeout-minutes"] == 30
    assert ios["swift-and-app-tests"]["timeout-minutes"] == 55


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
        # Pull requests share a key per number; run_id is only the fallback for pushes and manual runs, because a
        # pending run is dropped when another enters its group.
        assert concurrency["group"] == (
            "${{ github.workflow }}-${{ github.event.pull_request.number || github.run_id }}"
        ), workflow_name
        # Only pull request runs may be cancelled; pushes to main must all finish.
        assert concurrency["cancel-in-progress"] == "${{ github.event_name == 'pull_request' }}", workflow_name


def test_privacy_shield_capture_uses_only_resolved_package_versions() -> None:
    job = _jobs("privacy-shield.yml")["simulator-capture"]
    steps = cast("list[dict[str, object]]", job["steps"])
    capture = next(step for step in steps if step.get("name") == "Capture inactive app-switcher privacy behavior")
    words = shlex.split(str(capture["run"]))
    assert "-disableAutomaticPackageResolution" in words
    workflow = cast("dict[object, object]", yaml.safe_load((WORKFLOWS / "privacy-shield.yml").read_text()))
    normalized = {("on" if key is True else str(key)): value for key, value in workflow.items()}
    triggers = cast("dict[str, dict[str, object]]", normalized["on"])
    for trigger in ("pull_request", "push"):
        paths = cast("list[str]", cast("dict[str, object]", triggers[trigger])["paths"])
        assert "**/Package.resolved" in paths

    ios_raw = cast("dict[object, object]", yaml.safe_load((WORKFLOWS / "ios.yml").read_text()))
    ios_normalized = {("on" if key is True else str(key)): value for key, value in ios_raw.items()}
    ios_triggers = cast("dict[str, dict[str, object]]", ios_normalized["on"])
    for trigger in ("pull_request", "push"):
        ios_paths = cast("list[str]", cast("dict[str, object]", ios_triggers[trigger])["paths"])
        assert ".github/workflows/privacy-shield.yml" in ios_paths


def test_contract_changes_run_the_swift_tests_that_read_them() -> None:
    # The Swift fixture, digest, provider and bundled-schema tests read `contracts/` through `#filePath`,
    # so a pull request or push that changes only a contract has to start the workflow that runs
    # `swift test`; the contracts workflow by itself only lists the files.
    raw = cast("dict[object, object]", yaml.safe_load((WORKFLOWS / "ios.yml").read_text()))
    triggers = cast("dict[str, dict[str, object]]", raw.get(True, raw.get("on")))
    for event in ("pull_request", "push"):
        assert "contracts/**" in cast("list[str]", triggers[event]["paths"]), event
    steps = cast("list[dict[str, object]]", _jobs("ios.yml")["swift-and-app-tests"]["steps"])
    assert any(str(step.get("run", "")).strip() == "swift test" for step in steps)


def test_ios_workflow_pull_request_runs_hold_at_most_two_macos_runners() -> None:
    # The account has five concurrent macOS runners shared by every repository, so each macOS job this workflow
    # starts for a pull request push is a slot another run waits for. Release stays apart because it must use the
    # signed upload's image; everything that runs on macos-latest shares one job. (Other workflows, such as
    # privacy-shield.yml and catalog.yml, start their own macOS jobs on the paths they watch.)
    macos = [
        name
        for name, job in _jobs("ios.yml").items()
        if "macos" in str(job["runs-on"]).lower() and "pull_request" in str(job.get("if", "pull_request"))
    ]
    assert sorted(macos) == ["release-build", "swift-and-app-tests"], macos


def test_one_failing_check_does_not_hide_the_others_in_the_shared_job() -> None:
    steps = cast("list[dict[str, object]]", _jobs("ios.yml")["swift-and-app-tests"]["steps"])
    conditions = {str(step.get("name", "")): str(step.get("if", "")) for step in steps}
    # Every check runs even when an earlier one failed; each waits only on the step it needs.
    assert conditions == {
        "": "",  # checkout
        "Show Xcode version": "",
        "Test NutritionCore": "${{ !cancelled() }}",
        "Install XcodeGen (pinned release, checksum verified)": "${{ !cancelled() }}",
        "Generate the Xcode project": "${{ !cancelled() && steps.xcodegen.outcome == 'success' }}",
        "Build the app for the iOS Simulator": "${{ !cancelled() && steps.generate.outcome == 'success' }}",
        "Pick an available iPhone simulator": "${{ !cancelled() && steps.generate.outcome == 'success' }}",
        "Test the app target on the simulator": "${{ !cancelled() && steps.simulator.outcome == 'success' }}",
    }, conditions
    # Every step a condition waits on is declared before it, so a renamed or moved step cannot leave a condition
    # that reads an unknown id and silently skips the checks after it.
    declared: set[str] = set()
    for step in steps:
        for referenced in re.findall(r"steps\.([a-z0-9_-]+)\.outcome", str(step.get("if", ""))):
            assert referenced in declared, (step.get("name"), referenced)
        if "id" in step:
            declared.add(str(step["id"]))


def test_each_check_in_the_shared_job_has_its_own_deadline() -> None:
    # A hang in one check must not use up the job's whole budget and cancel the checks after it.
    job = _jobs("ios.yml")["swift-and-app-tests"]
    steps = {str(step.get("name", "")): step for step in cast("list[dict[str, object]]", job["steps"])}
    deadlines = [
        cast(int, steps[name]["timeout-minutes"])
        for name in (
            "Test NutritionCore",
            "Install XcodeGen (pinned release, checksum verified)",
            "Generate the Xcode project",
            "Build the app for the iOS Simulator",
            "Test the app target on the simulator",
        )
    ]
    assert all(minutes > 0 for minutes in deadlines), deadlines
    assert sum(deadlines) < cast(int, job["timeout-minutes"])
