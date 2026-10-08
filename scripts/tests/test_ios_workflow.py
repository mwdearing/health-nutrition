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


def test_release_build_uses_the_signed_upload_runner_image() -> None:
    release = _jobs("ios.yml")["release-build"]
    (signed,) = _jobs("signed-beta.yml").values()
    assert release["runs-on"] == signed["runs-on"]
    assert not str(release["runs-on"]).endswith("-latest")
