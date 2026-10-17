#!/usr/bin/env python3
"""The twice-daily signed beta: choose what to build, and say what was built.

`plan` (scheduled-beta.yml) picks the newest main commit whose `ios` run is green, skips when that commit
is already the last upload, and otherwise dispatches signed-beta on that exact commit with the next patch
version. `announce` (announce-beta.yml) runs when a signed-beta run finishes and posts the build, its
version and the pull requests merged since the last upload to one pinned issue, whose body also holds the
state the next plan reads: the last uploaded version and commit.

The decisions are pure functions so they can be tested without the network. Nothing here touches a secret:
the signed workflow keeps the key, and this script only reads public repository data and writes one issue.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.request
from collections.abc import Iterable
from datetime import datetime
from zoneinfo import ZoneInfo

ISSUE_TITLE = "TestFlight beta log"
STATE_START, STATE_END = "<!-- beta-state", "-->"
SHA = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
TITLE = re.compile(r"^Signed beta (?P<version>[0-9]+\.[0-9]+\.[0-9]+) (?P<sha>[0-9a-f]{40})$")
ACTIVE = ("queued", "in_progress", "waiting", "pending", "requested")
LOCAL_ZONE = ZoneInfo("America/Chicago")
LOCAL_HOURS = (11, 23)  # the noon and midnight builds, in Chicago time whichever offset applies


def next_version(version: str) -> str:
    if not VERSION.match(version):
        raise ValueError("a three-part version is required")
    major, minor, patch = (int(part) for part in version.split("."))
    return f"{major}.{minor}.{patch + 1}"


def parse_state(body: str | None) -> dict[str, str] | None:
    """The last uploaded version and commit from the issue body, or None when either is missing or malformed."""
    match = re.search(r"<!-- beta-state\n(?P<block>.*?)\n-->", body or "", re.S)
    if not match:
        return None
    values = dict(re.findall(r"^(last_version|last_sha):\s*(\S+)\s*$", match["block"], re.M))
    if not VERSION.match(values.get("last_version", "")) or not SHA.match(values.get("last_sha", "")):
        return None
    return values


def render_state(body: str | None, version: str, sha: str) -> str:
    """The body with its state block set to this version and commit, keeping the rest."""
    if not VERSION.match(version) or not SHA.match(sha):
        raise ValueError("a three-part version and a 40-character commit are required")
    block = f"<!-- beta-state\nlast_version: {version}\nlast_sha: {sha}\n-->"
    existing = body or ""
    if re.search(r"<!-- beta-state\n.*?\n-->", existing, re.S):
        return re.sub(r"<!-- beta-state\n.*?\n-->", block, existing, count=1, flags=re.S)
    return (existing.rstrip() + "\n\n" if existing.strip() else "") + block + "\n"


def in_build_window(now: datetime) -> bool:
    """True in the Chicago hours of the noon and midnight builds. The schedule lists the UTC times for both
    offsets, so exactly one firing of each pair lands in this window whichever offset is in force."""
    return now.astimezone(LOCAL_ZONE).hour in LOCAL_HOURS


def newest_green_sha(runs: Iterable[dict]) -> str | None:
    """The head of the newest successful push run of `ios` on main."""
    good = [
        run for run in runs
        if run.get("conclusion") == "success" and run.get("event") == "push" and run.get("head_branch") == "main"
        and SHA.match(run.get("head_sha", ""))
    ]
    good.sort(key=lambda run: run["created_at"], reverse=True)
    return good[0]["head_sha"] if good else None


def last_upload_version(signed_runs: Iterable[dict]) -> str | None:
    """The version in the name of the newest successful signed run that carries one, else None."""
    named = [
        (run["created_at"], parsed["version"])
        for run in signed_runs
        if run.get("conclusion") == "success" and (parsed := parse_title(run.get("display_title", "")))
    ]
    return max(named)[1] if named else None


def decide(green_sha: str | None, state: dict[str, str] | None, signed_runs: Iterable[dict]) -> dict[str, str]:
    """Either {"action": "skip", "reason": ...} or {"action": "dispatch", "version": ..., "sha": ...}."""
    signed_runs = list(signed_runs)
    if state is None:
        return {"action": "skip", "reason": "the beta log issue has no readable last version and commit"}
    recorded = last_upload_version(signed_runs)
    if recorded is not None and recorded != state["last_version"]:
        return {"action": "skip", "reason": "the beta log's last version disagrees with the last signed run's name"}
    if green_sha is None:
        return {"action": "skip", "reason": "no green ios run on main was found"}
    if any(run.get("status") in ACTIVE for run in signed_runs):
        return {"action": "skip", "reason": "a signed beta run is already queued, waiting or running"}
    if green_sha == state["last_sha"]:
        return {"action": "skip", "reason": "the newest green commit is already the last upload"}
    return {"action": "dispatch", "version": next_version(state["last_version"]), "sha": green_sha}


TRUSTED_AUTHORS = ("OWNER", "MEMBER", "COLLABORATOR")


def pick_state_issue(issues: Iterable[dict]) -> dict | None:
    """The oldest open issue with the log's title that someone with write access to the repository opened. Anyone
    can open an issue with any title, so a stranger's look-alike is never the state or the place to post."""
    for issue in issues:
        if (
            issue.get("title") == ISSUE_TITLE
            and "pull_request" not in issue
            and issue.get("author_association") in TRUSTED_AUTHORS
        ):
            return issue
    return None


def release_notes(subjects: Iterable[str]) -> str:
    """One bullet per merged pull request, without the trailing (#123) the squash merge adds."""
    trailing_number = re.compile(r" \(#[0-9]+\)$")
    lines = [f"- {trailing_number.sub('', subject.strip())}" for subject in subjects if subject.strip()]
    return "\n".join(lines) if lines else "- Nothing new since the last upload."


def parse_title(title: str) -> dict[str, str] | None:
    match = TITLE.match(title or "")
    return match.groupdict() if match else None


class Api:
    def __init__(self, repo: str, token: str) -> None:
        self.repo, self.token = repo, token

    def request(self, method: str, path: str, payload: dict | None = None) -> dict | list:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}{path}",
            method=method,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as response:  # noqa: S310 (fixed https host)
            body = response.read()
        return json.loads(body) if body else {}

    def runs(self, workflow: str, query: str = "") -> list[dict]:
        data = self.request("GET", f"/actions/workflows/{workflow}/runs?per_page=50{query}")
        return list(data.get("workflow_runs", [])) if isinstance(data, dict) else []

    def state_issue(self) -> dict | None:
        issues = self.request("GET", "/issues?state=open&per_page=100&sort=created&direction=asc")
        return pick_state_issue(issues if isinstance(issues, list) else [])


def _write_output(name: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")
    print(f"{name}={value}")


def plan() -> int:
    api = Api(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"])
    forced = os.environ.get("EVENT_NAME") == "workflow_dispatch"
    if not forced and not in_build_window(datetime.now(ZoneInfo("UTC"))):
        print("Not a noon or midnight Chicago hour; the other offset's firing handles this one.")
        _write_output("action", "skip")
        return 0
    issue = api.state_issue()
    state = parse_state(issue["body"]) if issue else None
    green = newest_green_sha(api.runs("ios.yml", "&branch=main&status=success&event=push"))
    active: list[dict] = []
    for status in ACTIVE:
        active += api.runs("signed-beta.yml", f"&status={status}")
    decision = decide(green, state, active + api.runs("signed-beta.yml", "&status=success"))
    print(json.dumps(decision))
    _write_output("action", decision["action"])
    if decision["action"] != "dispatch":
        print(f"::notice::No build this time: {decision['reason']}.")
        return 0
    api.request(
        "POST",
        "/actions/workflows/signed-beta.yml/dispatches",
        {"ref": "main", "inputs": {"marketing_version": decision["version"], "sha": decision["sha"]}},
    )
    print(f"Dispatched signed-beta for {decision['version']} at {decision['sha'][:7]}.")
    return 0


def _git_subjects(previous: str, sha: str) -> list[str]:
    result = subprocess.run(
        ["git", "log", "--first-parent", "--format=%s", f"{previous}..{sha}"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.splitlines()


def announce() -> int:
    api = Api(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"])
    title, conclusion = os.environ.get("RUN_TITLE", ""), os.environ.get("RUN_CONCLUSION", "")
    url, number = os.environ.get("RUN_URL", ""), int(os.environ.get("RUN_NUMBER", "0") or 0)
    parsed = parse_title(title)
    if parsed is None:
        print("The run was not started by the schedule (no version and commit in its name); nothing to post.")
        return 0
    issue = api.state_issue()
    if issue is None:
        print(f"::error::The issue {ISSUE_TITLE!r} does not exist, so there is nowhere to post.")
        return 1
    version, sha = parsed["version"], parsed["sha"]
    if conclusion != "success":
        api.request("POST", f"/issues/{issue['number']}/comments", {
            "body": f"**Build {version} at `{sha[:7]}` did not upload** ({conclusion}). Run: {url}"})
        return 0
    state = parse_state(issue["body"])
    notes = release_notes(_git_subjects(state["last_sha"], sha)) if state else release_notes([])
    api.request("POST", f"/issues/{issue['number']}/comments", {
        "body": f"**Build {number + 100} (version {version}) uploaded** from `{sha[:7]}`. Run: {url}\n\n"
                f"Merged since the last upload:\n{notes}"})
    api.request("PATCH", f"/issues/{issue['number']}", {"body": render_state(issue["body"], version, sha)})
    return 0


def main(argv: list[str]) -> int:
    commands = {"plan": plan, "announce": announce}
    if len(argv) != 2 or argv[1] not in commands:
        print("usage: beta_state.py plan|announce", file=sys.stderr)
        return 2
    return commands[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
