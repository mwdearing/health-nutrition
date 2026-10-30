#!/usr/bin/env python3
"""Cancel queued or running workflow runs that can no longer matter.

A run is stale when it belongs to a pull request whose head has moved on or whose pull request is
closed, when it is an older push run on the default branch than a newer run of the same workflow, or
when it has waited in the queue past a ceiling. Only the CI workflows named in CANCELLABLE are touched:
release, signing and manually dispatched runs are never cancelled here.

The decision is a pure function (`select_stale`) so it can be tested without the network.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone

CANCELLABLE = frozenset({"ios", "screenshots", "catalog", "design-system-tests"})
PULL_REQUEST_EVENTS = frozenset({"pull_request"})
MAX_QUEUED = timedelta(hours=6)


def _parse(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def select_stale(
    runs: Iterable[dict],
    open_pr_heads: dict[tuple[str, str], str],
    default_branch: str,
    now: datetime,
) -> list[dict]:
    """Return the runs to cancel.

    `runs` are workflow-run objects with status queued or in_progress. `open_pr_heads` maps
    (head repository full name, head branch) to the head SHA of its open pull request, so a fork's
    branch and a same-named branch of this repository are never confused.
    """
    runs = [r for r in runs if r.get("status") in ("queued", "in_progress", "waiting", "pending")]
    stale: dict[int, dict] = {}
    newest_push: dict[str, dict] = {}
    for run in runs:
        if run.get("name") not in CANCELLABLE:
            continue
        event = run.get("event")
        if event in PULL_REQUEST_EVENTS:
            key = ((run.get("head_repository") or {}).get("full_name"), run.get("head_branch"))
            if open_pr_heads.get(key) != run.get("head_sha"):
                stale[run["id"]] = run
        elif event == "push" and run.get("head_branch") == default_branch:
            key = run["name"]
            current = newest_push.get(key)
            if current is None or _parse(run["created_at"]) > _parse(current["created_at"]):
                if current is not None:
                    stale[current["id"]] = current
                newest_push[key] = run
            else:
                stale[run["id"]] = run
        if run.get("status") == "queued" and run["id"] not in stale:
            if now - _parse(run["created_at"]) > MAX_QUEUED:
                stale[run["id"]] = run
    return sorted(stale.values(), key=lambda r: r["id"])


class Api:
    def __init__(self, repo: str, token: str) -> None:
        self.repo, self.token = repo, token

    def request(self, method: str, path: str) -> dict:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}{path}",
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as response:  # noqa: S310 (fixed https host)
            body = response.read()
        return json.loads(body) if body else {}

    def pages(self, path: str, key: str) -> list[dict]:
        out: list[dict] = []
        sep = "&" if "?" in path else "?"
        for page in range(1, 11):
            data = self.request("GET", f"{path}{sep}per_page=100&page={page}")
            items = data.get(key, data) if isinstance(data, dict) else data
            out.extend(items)
            if len(items) < 100:
                break
        return out


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    api = Api(repo, os.environ["GITHUB_TOKEN"])
    dry_run = os.environ.get("DRY_RUN") == "1"
    default_branch = os.environ.get("DEFAULT_BRANCH", "main")
    # Forks are included: their runs are judged against their own head repository, never cancelled
    # for lacking a same-repository branch.
    open_heads = {
        ((pr["head"].get("repo") or {}).get("full_name"), pr["head"]["ref"]): pr["head"]["sha"]
        for pr in api.pages("/pulls?state=open", "pulls")
    }
    runs: list[dict] = []
    for status in ("queued", "in_progress"):
        runs += api.pages(f"/actions/runs?status={status}", "workflow_runs")
    stale = select_stale(runs, open_heads, default_branch, datetime.now(timezone.utc))
    print(f"{len(runs)} active runs, {len(stale)} stale")
    for run in stale:
        label = f"{run['name']} {run['event']} {run['head_branch']} {run['head_sha'][:7]} (run {run['id']})"
        if dry_run:
            print(f"would cancel {label}")
            continue
        try:
            api.request("POST", f"/actions/runs/{run['id']}/cancel")
            print(f"cancelled {label}")
        except urllib.error.HTTPError as error:
            # A run that finished a moment ago answers 409; that is fine.
            print(f"skipped {label}: HTTP {error.code}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
