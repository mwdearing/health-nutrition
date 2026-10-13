"""The stale-run selector decides which queued or running CI runs are cancelled."""
from __future__ import annotations

import runpy
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, cast

import yaml

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / ".github" / "scripts" / "cancel_stale_runs.py"
select_stale = cast(
    "Callable[[list[dict[str, Any]], dict[str, str], str, datetime], list[dict[str, Any]]]",
    runpy.run_path(str(SCRIPT))["select_stale"],
)
NOW = datetime(2026, 10, 13, 18, 0, tzinfo=timezone.utc)


def run(run_id: int, **kw: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "id": run_id, "name": "ios", "event": "pull_request", "status": "queued",
        "head_branch": "feature/a", "head_sha": "a" * 40,
        "created_at": (NOW - timedelta(minutes=10)).isoformat(),
    }
    base.update(kw)
    return base


def ids(runs: list[dict[str, Any]]) -> list[int]:
    return [r["id"] for r in runs]


def test_current_head_of_open_pr_is_kept() -> None:
    heads = {"feature/a": "a" * 40}
    assert select_stale([run(1)], heads, "main", NOW) == []


def test_run_for_a_superseded_head_is_cancelled() -> None:
    heads = {"feature/a": "b" * 40}
    assert ids(select_stale([run(1)], heads, "main", NOW)) == [1]


def test_run_for_a_closed_pull_request_is_cancelled() -> None:
    assert ids(select_stale([run(1)], {}, "main", NOW)) == [1]


def test_only_the_newest_default_branch_push_run_is_kept() -> None:
    old = run(1, event="push", head_branch="main", created_at=(NOW - timedelta(hours=2)).isoformat())
    new = run(2, event="push", head_branch="main", created_at=(NOW - timedelta(hours=1)).isoformat())
    assert ids(select_stale([old, new], {}, "main", NOW)) == [1]
    assert ids(select_stale([new, old], {}, "main", NOW)) == [1]


def test_workflows_outside_the_allowlist_are_never_touched() -> None:
    for name in ("signed-beta", "Attribution check", "release"):
        assert select_stale([run(1, name=name)], {}, "main", NOW) == []


def test_manual_and_scheduled_runs_are_never_cancelled_for_head_reasons() -> None:
    manual = run(1, event="workflow_dispatch", head_branch="feature/z")
    scheduled = run(2, event="schedule", head_branch="main")
    assert select_stale([manual, scheduled], {}, "main", NOW) == []


def test_a_run_queued_past_the_ceiling_is_cancelled_even_on_a_current_head() -> None:
    heads = {"feature/a": "a" * 40}
    aged = run(1, created_at=(NOW - timedelta(hours=7)).isoformat())
    assert ids(select_stale([aged], heads, "main", NOW)) == [1]


def test_completed_runs_are_ignored() -> None:
    assert select_stale([run(1, status="completed")], {}, "main", NOW) == []


def test_workflow_triggers_and_permissions() -> None:
    workflow = yaml.safe_load((REPO / ".github" / "workflows" / "cancel-stale-runs.yml").read_text())
    triggers = workflow.get("on", workflow.get(True))
    assert "schedule" in triggers and "workflow_dispatch" in triggers
    assert workflow["permissions"]["actions"] == "write"
    text = (REPO / ".github" / "workflows" / "cancel-stale-runs.yml").read_text()
    assert "pull_request_target" in text and "ref: ${{ github.event.repository.default_branch }}" in text
