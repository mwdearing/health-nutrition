"""The twice-daily signed beta: what it builds, when, and what it says afterwards.

The decisions live in .github/scripts/beta_state.py as pure functions. The workflow tests pin the parts that
keep the unattended signing safe: the signed workflow only builds a commit that is already on main, takes the
commit through the environment and never into script text, and the schedule and announce workflows hold no
signing secret.
"""

from __future__ import annotations

import re
import runpy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, cast

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github/workflows"
beta = runpy.run_path(str(REPO / ".github/scripts/beta_state.py"))
A, B = "a" * 40, "b" * 40


def _workflow(name: str) -> dict[str, Any]:
    raw = cast("dict[Any, Any]", yaml.safe_load((WORKFLOWS / name).read_text()))
    return {("on" if key is True else str(key)): value for key, value in raw.items()}


def _run_scripts(name: str) -> list[str]:
    (job,) = cast("dict[str, dict[str, Any]]", _workflow(name)["jobs"]).values()
    return [str(step["run"]) for step in job["steps"] if "run" in step]


def test_the_next_version_raises_the_patch_only() -> None:
    assert beta["next_version"]("0.1.30") == "0.1.31"
    assert beta["next_version"]("1.9.9") == "1.9.10"
    with pytest.raises(ValueError):
        beta["next_version"]("0.1")


def test_state_round_trips_and_keeps_the_rest_of_the_issue() -> None:
    body = beta["render_state"]("Notes for the team.\n", "0.1.30", A)
    assert body.startswith("Notes for the team.")
    assert beta["parse_state"](body) == {"last_version": "0.1.30", "last_sha": A}
    again = beta["render_state"](body, "0.1.31", B)
    assert again.count("beta-state") == 1
    assert again.startswith("Notes for the team.")
    assert beta["parse_state"](again) == {"last_version": "0.1.31", "last_sha": B}


@pytest.mark.parametrize(
    "body",
    [None, "", "no block", "<!-- beta-state\nlast_version: 0.1\nlast_sha: " + A + "\n-->", "<!-- beta-state\nlast_version: 0.1.30\nlast_sha: abc\n-->"],
)
def test_unreadable_state_is_none(body: str | None) -> None:
    assert beta["parse_state"](body) is None


def test_state_refuses_a_malformed_version_or_commit() -> None:
    with pytest.raises(ValueError):
        beta["render_state"]("", "0.1", A)
    with pytest.raises(ValueError):
        beta["render_state"]("", "0.1.30", "abc")


@pytest.mark.parametrize(
    ("utc", "expected"),
    [
        ((2026, 10, 18, 4, 40), True),     # 23:40 CDT, on time
        ((2026, 10, 18, 5, 40), True),     # 00:40 CDT, a late start still builds
        ((2026, 10, 18, 6, 10), True),     # 01:10 CDT, a late midnight start
        ((2026, 10, 18, 16, 40), True),    # 11:40 CDT
        ((2026, 10, 18, 17, 40), True),    # 12:40 CDT, a late start
        ((2026, 10, 18, 18, 10), True),    # 13:10 CDT, a late noon start
        ((2026, 10, 18, 3, 40), False),    # 22:40 CDT
        ((2026, 10, 18, 19, 14), True),    # 14:14 CDT, the 2026-10-25 noon start that skipped
        ((2026, 10, 18, 21, 10), False),   # 16:10 CDT, too late for noon
        ((2026, 11, 2, 5, 40), True),      # 23:40 CST
        ((2026, 11, 2, 4, 40), False),     # 22:40 CST
        ((2026, 11, 2, 17, 40), True),     # 11:40 CST
        ((2026, 11, 2, 16, 40), False),    # 10:40 CST
    ],
)
def test_a_firing_up_to_an_hour_late_is_still_in_the_build_window(utc: tuple[int, ...], expected: bool) -> None:
    assert beta["in_build_window"](datetime(*utc, tzinfo=timezone.utc)) is expected


def _run(sha: str, created: str, **kw: Any) -> dict[str, Any]:
    run = {"conclusion": "success", "event": "push", "head_branch": "main", "head_sha": sha, "created_at": created}
    run.update(kw)
    return run


def test_the_newest_green_push_run_on_main_is_chosen() -> None:
    runs = [
        _run(A, "2026-10-18T01:00:00Z"),
        _run(B, "2026-10-18T03:00:00Z"),
        _run("c" * 40, "2026-10-18T04:00:00Z", conclusion="failure"),
        _run("d" * 40, "2026-10-18T05:00:00Z", head_branch="feature/x"),
        _run("e" * 40, "2026-10-18T06:00:00Z", event="pull_request"),
    ]
    assert beta["newest_green_sha"](runs) == B
    assert beta["newest_green_sha"]([]) is None


STATE = {"last_version": "0.1.30", "last_sha": A}


def test_a_new_green_commit_is_dispatched_with_the_next_patch() -> None:
    assert beta["decide"](B, STATE, []) == {"action": "dispatch", "version": "0.1.31", "sha": B}


@pytest.mark.parametrize(
    ("green", "state", "signed"),
    [
        (A, STATE, []),                                   # already the last upload
        (None, STATE, []),                                # no green run
        (B, None, []),                                    # no readable state
        (B, STATE, [{"status": "waiting"}]),              # a run is waiting for approval
        (B, STATE, [{"status": "in_progress"}]),
        (B, STATE, [{"status": "queued"}]),
    ],
)
def test_the_plan_skips_instead_of_guessing(green: str | None, state: Any, signed: list[dict[str, str]]) -> None:
    assert beta["decide"](green, state, signed)["action"] == "skip"


def test_a_finished_signed_run_does_not_block_the_next_one() -> None:
    assert beta["decide"](B, STATE, [{"status": "completed"}])["action"] == "dispatch"


def test_release_notes_list_each_merge_without_its_pull_request_number() -> None:
    notes = beta["release_notes"](["Add a thing (#12)", "Fix the (#3) bug", "", "Last (#4)"])
    assert notes == "- Add a thing\n- Fix the (#3) bug\n- Last"
    assert beta["release_notes"]([]) == "- Nothing new since the last upload."


def test_the_run_name_is_read_back_as_data_and_never_trusted_loosely() -> None:
    assert beta["parse_title"](f"Signed beta 0.1.31 {B}") == {"version": "0.1.31", "sha": B}
    for title in ("Signed beta upload", f"Signed beta 0.1.31 {B[:7]}", f"Signed beta 0.1.31 {B}; rm -rf /", ""):
        assert beta["parse_title"](title) is None


def test_the_signed_workflow_builds_only_a_commit_on_main_and_passes_it_by_environment() -> None:
    signed = _workflow("signed-beta.yml")
    (job,) = cast("dict[str, dict[str, Any]]", signed["jobs"]).values()
    steps = cast("list[dict[str, Any]]", job["steps"])
    names = [str(step.get("name")) for step in steps]
    gate = names.index("Check the commit to build is on main")
    checkout = names.index("Check out repository")
    assert gate < checkout
    assert steps[gate]["env"]["SHA"] == "${{ inputs.sha }}"
    run = str(steps[gate]["run"])
    assert "compare/$SHA...$GITHUB_SHA" in run and '"identical"' in run and '"ahead"' in run
    assert "[0-9a-f]{40}" in run
    assert steps[checkout]["with"]["ref"] == "${{ inputs.sha || github.sha }}"
    assert signed["permissions"] == {"contents": "read"}
    for script in (str(step.get("run", "")) for step in steps):
        assert "inputs.sha" not in script, "the commit must reach scripts only through the environment"
    assert "inputs.sha" in str(signed["run-name"]) and "inputs.marketing_version" in str(signed["run-name"])


def test_the_scheduled_workflow_lists_both_offsets_and_holds_no_signing_secret() -> None:
    schedule = _workflow("scheduled-beta.yml")
    assert schedule["on"]["schedule"] == [{"cron": "40 4,5,16,17 * * *"}]
    assert set(schedule["on"]) == {"schedule", "workflow_dispatch"}
    assert schedule["permissions"] == {"actions": "write", "issues": "read", "contents": "read"}
    text = (WORKFLOWS / "scheduled-beta.yml").read_text()
    assert "secrets." not in text and "environment:" not in text


def test_the_announce_workflow_can_only_write_issues_and_reads_the_run_as_data() -> None:
    announce = _workflow("announce-beta.yml")
    assert announce["on"]["workflow_run"] == {"workflows": ["Signed beta upload"], "types": ["completed"]}
    assert announce["permissions"] == {"contents": "read", "issues": "write"}
    text = (WORKFLOWS / "announce-beta.yml").read_text()
    (job,) = cast("dict[str, dict[str, Any]]", announce["jobs"]).values()
    condition = " ".join(str(job["if"]).split())
    for required in (
        "workflow_run.path == '.github/workflows/signed-beta.yml'",
        "workflow_run.event == 'workflow_dispatch'",
        "workflow_run.head_branch == 'main'",
        "workflow_run.head_repository.full_name == github.repository",
    ):
        assert required in condition
    assert "secrets." not in text
    for script in _run_scripts("announce-beta.yml") + _run_scripts("scheduled-beta.yml"):
        assert not re.search(r"\$\{\{", script), "event data must reach scripts only through the environment"
    checkout = text.split("actions/checkout", 1)[1]
    assert "ref: main" in checkout and "persist-credentials: false" in checkout


def _issue(**kw: Any) -> dict[str, Any]:
    issue = {"title": "TestFlight beta log", "author_association": "OWNER", "number": 1}
    issue.update(kw)
    return issue


def test_only_the_repository_owners_log_issue_counts() -> None:
    pick = beta["pick_state_issue"]
    assert pick([_issue()])["number"] == 1
    assert pick([_issue(author_association="NONE", number=2), _issue(number=3)])["number"] == 3
    assert pick([_issue(author_association="NONE")]) is None
    assert pick([_issue(pull_request={})]) is None
    assert pick([_issue(title="Something else")]) is None
    assert pick([_issue(author_association="FIRST_TIME_CONTRIBUTOR")]) is None


NOW = datetime(2026, 10, 19, 4, 45, tzinfo=timezone.utc)


def _signed(version: str, sha: str, finished: str, **kw: Any) -> dict[str, Any]:
    run = {"conclusion": "success", "display_title": f"Signed beta {version} {sha}", "created_at": finished,
           "updated_at": finished, "status": "completed"}
    run.update(kw)
    return run


def test_a_failed_issue_update_cannot_make_the_schedule_repeat_a_version() -> None:
    stale_issue = {"last_version": "0.1.30", "last_sha": A}
    runs = [_signed("0.1.31", B, "2026-10-18T17:00:00Z")]
    decision = beta["decide"]("c" * 40, stale_issue, runs, NOW)
    assert decision == {"action": "dispatch", "version": "0.1.32", "sha": "c" * 40}


def test_an_older_manual_run_cannot_rewind_the_state() -> None:
    issue = {"last_version": "0.1.31", "last_sha": B}
    runs = [_signed("0.1.20", A, "2026-10-18T23:00:00Z")]
    assert beta["effective_state"](issue, runs) == issue
    assert beta["effective_state"](None, runs)["last_version"] == "0.1.20"


def test_a_build_less_than_six_hours_ago_blocks_the_second_firing_of_a_pair() -> None:
    state = {"last_version": "0.1.30", "last_sha": A, "last_time": "2026-10-19T04:50:00Z"}
    early = datetime(2026, 10, 19, 5, 40, tzinfo=timezone.utc)
    assert beta["decide"](B, state, [], early)["action"] == "skip"
    later = datetime(2026, 10, 19, 11, 0, 1, tzinfo=timezone.utc)
    assert beta["decide"](B, state, [], later)["action"] == "dispatch"


def test_state_remembers_the_time_and_ignores_a_garbled_one() -> None:
    body = beta["render_state"]("", "0.1.30", A, "2026-10-19T04:50:00Z")
    assert beta["parse_state"](body)["last_time"] == "2026-10-19T04:50:00Z"
    garbled = body.replace("2026-10-19T04:50:00Z", "yesterday")
    assert "last_time" not in beta["parse_state"](garbled)
    naive = body.replace("2026-10-19T04:50:00Z", "2026-10-19T04:50:00")
    assert "last_time" not in beta["parse_state"](naive)
    assert "last_time" not in beta["parse_state"](beta["render_state"]("", "0.1.30", A))


def test_collaborators_with_read_access_do_not_count_as_trusted_authors() -> None:
    assert beta["pick_state_issue"]([_issue(author_association="COLLABORATOR")]) is None
    assert beta["pick_state_issue"]([_issue(author_association="MEMBER")])["number"] == 1


def test_the_announce_workflow_passes_the_finish_time_through_the_environment() -> None:
    text = (WORKFLOWS / "announce-beta.yml").read_text()
    assert "RUN_UPDATED: ${{ github.event.workflow_run.updated_at }}" in text


def test_an_unreadable_commit_range_gives_no_notes_instead_of_crashing(tmp_path: Path, monkeypatch: Any) -> None:
    import subprocess

    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    monkeypatch.chdir(tmp_path)
    assert beta["_git_subjects"](A, B) == []
