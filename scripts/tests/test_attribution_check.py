"""Regression tests for the PR attribution scanner's input parsing."""
from __future__ import annotations

import os
import runpy
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import cast

import pytest
import yaml

SCRIPT = Path(__file__).resolve().parents[2] / ".github" / "scripts" / "attribution_check.py"
REPO = SCRIPT.parents[2]
COAUTHOR_TRAILER = "Co-Authored-" + "By:"
IS_AGENT_IDENTITY = cast(
    "Callable[[str], bool]", runpy.run_path(str(SCRIPT))["is_agent_identity"]
)


def run_check(body: str, *, timeout: float = 5) -> subprocess.CompletedProcess[str]:
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout.strip()
    env = os.environ.copy()
    env.update({
        "PR_TITLE": "Scanner tests",
        "PR_BODY": body,
        "HEAD_REF": "test/scanner-tests",
        "PR_AUTHOR": "human",
        "BASE_SHA": head,
        "HEAD_SHA": head,
    })
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=REPO,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def test_pr_body_agent_coauthor_is_still_rejected() -> None:
    result = run_check(f"{COAUTHOR_TRAILER} Claude Code <noreply@openai.com>")
    assert result.returncode == 1
    assert f"PR body: {COAUTHOR_TRAILER[:-1]} trailer naming an agent" in result.stdout


def test_person_identity_with_agent_like_name_and_company_address_is_allowed() -> None:
    result = run_check(f"{COAUTHOR_TRAILER} Claude Smith <claude@company.example>")
    assert result.returncode == 0, result.stdout + result.stderr


def test_agent_name_is_rejected_even_when_mailbox_syntax_is_malformed() -> None:
    result = run_check(f"{COAUTHOR_TRAILER} Claude Code <<bot@example.com>")
    assert result.returncode == 1
    assert f"PR body: {COAUTHOR_TRAILER[:-1]} trailer naming an agent" in result.stdout


def test_agent_bot_suffix_remains_rejected() -> None:
    result = run_check(f"{COAUTHOR_TRAILER} project-claude[bot]")
    assert result.returncode == 1


@pytest.mark.parametrize(
    "identity",
    [
        "Claude Code <bot@example.com",
        "Claude Code bot@example.com>",
        "Claude Code > <bot@example.com>",
    ],
)
def test_agent_name_is_rejected_despite_malformed_outer_brackets(identity: str) -> None:
    result = run_check(f"{COAUTHOR_TRAILER} {identity}")
    assert result.returncode == 1
    assert f"PR body: {COAUTHOR_TRAILER[:-1]} trailer naming an agent" in result.stdout


@pytest.mark.parametrize(
    "identity",
    [
        "Jane Doe <jane@example.com",
        "Jane Doe jane@example.com>",
        "Jane Doe > <jane@example.com>",
    ],
)
def test_human_name_with_malformed_outer_brackets_remains_allowed(identity: str) -> None:
    result = run_check(f"{COAUTHOR_TRAILER} {identity}")
    assert result.returncode == 0, result.stdout + result.stderr


def test_malformed_identity_with_many_agent_tokens_stays_bounded() -> None:
    identity = "Claude " * 40_000 + ">"
    started = time.perf_counter()
    assert IS_AGENT_IDENTITY(identity) is False
    assert time.perf_counter() - started < 1.0


def test_agent_name_with_hostile_whitespace_is_rejected_in_bounded_time() -> None:
    body = COAUTHOR_TRAILER + " Claude Code" + (" " * 80_000) + "<noreply@openai.com"
    result = run_check(body)
    assert result.returncode == 1
    assert f"PR body: {COAUTHOR_TRAILER[:-1]} trailer naming an agent" in result.stdout


def test_human_identity_with_hostile_whitespace_remains_allowed() -> None:
    body = COAUTHOR_TRAILER + " Jane Doe" + (" " * 80_000) + "<jane@example.com"
    result = run_check(body)
    assert result.returncode == 0, result.stdout + result.stderr


def test_pr_body_attribution_enforcement_keeps_its_five_minute_deadline() -> None:
    workflow = REPO / ".github" / "workflows" / "attribution-check.yml"
    raw = yaml.safe_load(workflow.read_text())
    (job,) = raw["jobs"].values()
    assert job["timeout-minutes"] == 5


def test_agent_mailbox_is_rejected_despite_stray_display_name_bracket() -> None:
    result = run_check(f"{COAUTHOR_TRAILER} Jane > <codex@openai.com>")
    assert result.returncode == 1


def test_agent_mailbox_after_stray_display_name_bracket_is_rejected() -> None:
    result = run_check(f"{COAUTHOR_TRAILER} Jane <alias> <noreply@openai.com>")
    assert result.returncode == 1
    assert f"PR body: {COAUTHOR_TRAILER[:-1]} trailer naming an agent" in result.stdout


def test_human_identity_with_complete_mailbox_is_allowed() -> None:
    result = run_check(f"{COAUTHOR_TRAILER} Jane Doe <jane@example.com>")
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    "identity",
    [
        "Jane <project-claude[bot]",
        "Jane <alias> <noreply@openai.com>",
        "Jane > <noreply@anthropic.com>",
        "Claude Code <<bot@example.com>",
        "Jane <<noreply@openai.com>>",
    ],
)
def test_bot_identity_is_rejected_in_any_bracket_segment(identity: str) -> None:
    result = run_check(f"{COAUTHOR_TRAILER} {identity}")
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"PR body: {COAUTHOR_TRAILER[:-1]} trailer naming an agent" in result.stdout


@pytest.mark.parametrize(
    "identity",
    [
        "Jane Doe <jane@example.com>",
        "Jane Doe <jane.doe+work@example.org>",
        "Jane (JD) Doe <jane@example.com>",
    ],
)
def test_human_identity_with_bracketed_nickname_or_mailbox_is_allowed(identity: str) -> None:
    result = run_check(f"{COAUTHOR_TRAILER} {identity}")
    assert result.returncode == 0, result.stdout + result.stderr


def test_swift_lint_triggers_on_attribution_workflow() -> None:
    workflow = REPO / ".github" / "workflows" / "swift-lint.yml"
    raw = yaml.safe_load(workflow.read_text())
    triggers = raw.get(True, raw.get("on"))
    attribution = ".github/workflows/attribution-check.yml"
    assert attribution in triggers["pull_request"]["paths"]
    assert attribution in triggers["push"]["paths"]


def test_target_workflow_uses_the_event_base_commit_and_never_executes_pr_code() -> None:
    raw = yaml.safe_load((REPO / ".github/workflows/attribution-check.yml").read_text())
    assert raw["permissions"] == {"contents": "read"}
    triggers = raw.get("on", raw.get(True))
    assert set(triggers) == {"pull_request_target"}
    (job,) = raw["jobs"].values()
    checkout = next(step for step in job["steps"] if "actions/checkout@" in step.get("uses", ""))
    assert checkout["with"].get("ref") == "${{ github.event.pull_request.base.sha }}"
    assert checkout["with"]["persist-credentials"] is False
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert 'git fetch --no-tags origin "refs/pull/${PR_NUMBER}/head"' in commands
    assert "git checkout" not in commands and "git switch" not in commands
    assert commands.endswith("python3 .github/scripts/attribution_check.py")
