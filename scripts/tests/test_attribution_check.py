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
