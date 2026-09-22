#!/usr/bin/env python3
"""
Fetch and maintain a rerunnable triage ledger for mobile feedback/crashes.

Default run:
  ./tools/scripts/triage-mobile-feedback.py --last-hours 24

Useful follow-ups:
  ./tools/scripts/triage-mobile-feedback.py list
  ./tools/scripts/triage-mobile-feedback.py mark testflight:feedback:ABC --status done --note "Fixed in 1.0.5"

The script keeps local state under artifacts/mobile-triage by default. That
directory is gitignored, so raw fetched data and triage notes stay local unless
you explicitly move them somewhere else.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


UTC = dt.timezone.utc

DEFAULT_STATE_DIR = pathlib.Path("artifacts/mobile-triage")
DEFAULT_FETCHER = pathlib.Path(__file__).resolve().parent / "fetch-mobile-store-artifacts.py"

ACTIVE_STATUSES = {"new", "triaging", "blocked"}
FINAL_STATUSES = {"done", "ignored", "duplicate", "pr-open"}
STATUSES = tuple(sorted(ACTIVE_STATUSES | FINAL_STATUSES))
PRIORITIES = ("unset", "p0", "p1", "p2", "p3")


class ScriptError(RuntimeError):
    pass


def iso_now() -> str:
    return dt.datetime.now(tz=UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: str) -> dt.datetime:
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(raw)
    # Naive values use the local offset for their own date, including DST.
    return parsed.astimezone(UTC)


def compute_window(args: argparse.Namespace) -> tuple[dt.datetime, dt.datetime]:
    now = dt.datetime.now(tz=UTC)
    until = parse_timestamp(args.until) if args.until else now
    if args.last_hours is not None:
        since = until - dt.timedelta(hours=args.last_hours)
    elif args.since:
        since = parse_timestamp(args.since)
    else:
        since = until - dt.timedelta(hours=24)
    if since >= until:
        raise ScriptError(f"Invalid window: since {since.isoformat()} is not before until {until.isoformat()}")
    return since, until


def parse_args(argv: list[str]) -> argparse.Namespace:
    command_argv = list(argv)
    if not command_argv or command_argv[0].startswith("-"):
        command_argv.insert(0, "run")

    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Fetch sources and update the triage ledger.")
    window = run_parser.add_mutually_exclusive_group(required=False)
    window.add_argument("--last-hours", type=float, help="Fetch artifacts from the last N hours.")
    window.add_argument("--since", help="ISO-8601 start time. Naive timestamps use the local timezone.")
    run_parser.add_argument("--until", help="ISO-8601 end time. Defaults to now.")
    run_parser.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR), help="Local triage state directory.")
    run_parser.add_argument("--fetcher", default=str(DEFAULT_FETCHER), help="Path to fetch-mobile-store-artifacts.py.")
    run_parser.add_argument("--store-artifacts-dir", help="Ingest an existing store fetch directory instead of fetching.")
    run_parser.add_argument("--skip-store", action="store_true", help="Skip TestFlight/Play ingestion.")
    run_parser.add_argument("--skip-ios", action="store_true", help="Pass through to the store fetcher.")
    run_parser.add_argument("--skip-android", action="store_true", help="Pass through to the store fetcher.")
    run_parser.add_argument("--ios-bundle-id", help="Pass through to the store fetcher.")
    run_parser.add_argument("--android-package", help="Pass through to the store fetcher.")
    run_parser.add_argument("--ios-version", help="Pass through to the store fetcher.")
    run_parser.add_argument("--asc-bin", help="Pass through to the store fetcher.")
    run_parser.add_argument("--play-service-account-json", help="Pass through to the store fetcher.")
    run_parser.add_argument("--play-env-file", help="Pass through to the store fetcher.")
    run_parser.add_argument("--no-download-ios-screenshots", action="store_true", help="Pass through to the store fetcher.")
    run_parser.add_argument("--skip-github", action="store_true", help="Skip GitHub issue/PR ingestion.")
    run_parser.add_argument("--github-repo", help="owner/repo. Defaults to the origin remote.")
    run_parser.add_argument("--github-token", help="GitHub token. Defaults to GITHUB_TOKEN or GH_TOKEN.")
    run_parser.add_argument(
        "--no-github-open-backfill",
        action="store_true",
        help="Only fetch GitHub issues/PRs updated in the requested window.",
    )

    mark_parser = subparsers.add_parser("mark", help="Set status/metadata for one or more item IDs.")
    mark_parser.add_argument("item_ids", nargs="+")
    mark_parser.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR), help="Local triage state directory.")
    mark_parser.add_argument("--status", choices=STATUSES, required=True)
    mark_parser.add_argument("--note", help="Append a note to each item.")
    mark_parser.add_argument("--owner", help="Set owner.")
    mark_parser.add_argument("--priority", choices=PRIORITIES, help="Set priority.")
    mark_parser.add_argument("--resolution", help="Set resolution text.")

    list_parser = subparsers.add_parser("list", help="Print ledger items without fetching.")
    list_parser.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR), help="Local triage state directory.")
    list_parser.add_argument(
        "--status",
        default="active",
        choices=("active", "all", *STATUSES),
        help="Filter by status.",
    )
    list_parser.add_argument("--source", choices=("github", "testflight", "play"), help="Filter by source.")

    return parser.parse_args(command_argv)


def ensure_dir(path: pathlib.Path) -> pathlib.Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def load_json(path: pathlib.Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text())


def write_json(path: pathlib.Path, payload: Any) -> None:
    ensure_dir(path.parent)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")


def state_paths(state_dir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    return state_dir / "triage-state.json", state_dir / "triage-board.md"


def initial_state() -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "createdAtUtc": iso_now(),
        "updatedAtUtc": iso_now(),
        "latestRunId": None,
        "items": {},
    }


def load_state(state_dir: pathlib.Path) -> dict[str, Any]:
    state_path, _ = state_paths(state_dir)
    state = load_json(state_path, initial_state())
    state.setdefault("schemaVersion", 1)
    state.setdefault("createdAtUtc", iso_now())
    state.setdefault("items", {})
    return state


def save_state(state_dir: pathlib.Path, state: dict[str, Any]) -> None:
    state["updatedAtUtc"] = iso_now()
    state_path, _ = state_paths(state_dir)
    write_json(state_path, state)


def run_command(argv: list[str], *, cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        check=False,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        command = " ".join(shlex.quote(part) for part in argv)
        raise ScriptError(
            f"Command failed ({completed.returncode}): {command}\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return completed


def infer_github_repo() -> str:
    remote = run_command(["git", "remote", "get-url", "origin"]).stdout.strip()
    if remote.startswith("git@github.com:"):
        value = remote.split(":", 1)[1]
    elif "github.com/" in remote:
        value = remote.split("github.com/", 1)[1]
    else:
        raise ScriptError("Could not infer GitHub repo from origin remote. Pass --github-repo owner/repo.")
    value = value.removesuffix(".git").strip("/")
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", value):
        raise ScriptError(f"Could not infer GitHub repo from origin remote: {remote}")
    return value


def parse_link_next(header: str | None) -> str | None:
    if not header:
        return None
    for part in header.split(","):
        section = part.strip()
        if 'rel="next"' not in section:
            continue
        match = re.search(r"<([^>]+)>", section)
        if match:
            return match.group(1)
    return None


def github_get_json(url: str, token: str | None) -> tuple[list[dict[str, Any]], str | None]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "litter-mobile-triage/1.0",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            payload = json.loads(response.read().decode())
            if not isinstance(payload, list):
                raise ScriptError(f"Expected GitHub list response for {url}: {payload}")
            return payload, parse_link_next(response.headers.get("Link"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        raise ScriptError(f"GitHub HTTP {exc.code} for {url}: {body}") from exc


def fetch_github_page_set(base_url: str, token: str | None) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    next_url: str | None = base_url
    while next_url:
        payload, next_url = github_get_json(next_url, token)
        rows.extend(payload)
    return rows


def fetch_github_issues(
    *,
    repo: str,
    token: str | None,
    since: dt.datetime,
    until: dt.datetime,
    open_backfill: bool,
    output_dir: pathlib.Path,
) -> dict[str, Any]:
    base = f"https://api.github.com/repos/{repo}/issues"
    since_iso = since.isoformat().replace("+00:00", "Z")
    updated_params = urllib.parse.urlencode(
        {
            "state": "all",
            "since": since_iso,
            "per_page": "100",
            "sort": "updated",
            "direction": "desc",
        }
    )
    rows_by_id: dict[int, dict[str, Any]] = {}
    for issue in fetch_github_page_set(f"{base}?{updated_params}", token):
        updated_at = issue.get("updated_at")
        if updated_at and parse_timestamp(updated_at) > until:
            continue
        rows_by_id[int(issue["id"])] = issue

    if open_backfill:
        open_params = urllib.parse.urlencode(
            {
                "state": "open",
                "per_page": "100",
                "sort": "updated",
                "direction": "desc",
            }
        )
        for issue in fetch_github_page_set(f"{base}?{open_params}", token):
            rows_by_id[int(issue["id"])] = issue

    issues = sorted(rows_by_id.values(), key=lambda row: row.get("updated_at") or "", reverse=True)
    issue_count = sum(1 for issue in issues if "pull_request" not in issue)
    pr_count = len(issues) - issue_count
    result = {
        "repo": repo,
        "fetchedAtUtc": iso_now(),
        "windowUtc": {
            "since": since.isoformat().replace("+00:00", "Z"),
            "until": until.isoformat().replace("+00:00", "Z"),
        },
        "openBackfill": open_backfill,
        "issueCount": issue_count,
        "pullRequestCount": pr_count,
        "itemCount": len(issues),
        "issues": issues,
    }
    github_dir = ensure_dir(output_dir / "github")
    write_json(github_dir / "issues.json", result)
    return result


def maybe_read_json(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def first_user_comment(review: dict[str, Any]) -> dict[str, Any]:
    for comment in reversed(review.get("comments") or []):
        user_comment = comment.get("userComment") or {}
        if user_comment:
            return user_comment
    return {}


def one_line(value: str | None, *, fallback: str, limit: int = 120) -> str:
    text = " ".join((value or "").strip().split())
    if not text:
        return fallback
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "..."


def rel_to_state(path: pathlib.Path, state_dir: pathlib.Path) -> str:
    try:
        return str(path.resolve().relative_to(state_dir.resolve()))
    except ValueError:
        return str(path)


def item_record(
    *,
    item_id: str,
    source: str,
    kind: str,
    title: str,
    source_created_at: str | None,
    source_updated_at: str | None,
    source_state: str,
    details: str,
    url: str | None,
    artifact_refs: list[str],
    run_id: str,
) -> dict[str, Any]:
    return {
        "id": item_id,
        "source": source,
        "kind": kind,
        "title": title,
        "sourceCreatedAt": source_created_at,
        "sourceUpdatedAt": source_updated_at,
        "sourceState": source_state,
        "details": details,
        "url": url,
        "artifactRefs": artifact_refs,
        "lastRunId": run_id,
    }


def normalize_github_items(github_payload: dict[str, Any], *, state_dir: pathlib.Path, run_dir: pathlib.Path, run_id: str) -> list[dict[str, Any]]:
    repo = github_payload.get("repo", "unknown/repo")
    artifact = rel_to_state(run_dir / "github" / "issues.json", state_dir)
    items = []
    for issue in github_payload.get("issues") or []:
        number = issue.get("number")
        is_pr = "pull_request" in issue
        github_kind = "github-pr" if is_pr else "github-issue"
        id_kind = "pr" if is_pr else "issue"
        item_id = f"github:{id_kind}:{repo}#{number}"
        labels = [label.get("name") for label in issue.get("labels") or [] if label.get("name")]
        label_text = ", ".join(labels) if labels else "none"
        details = f"state: {issue.get('state', 'unknown')} | labels: {label_text}"
        if is_pr:
            draft = issue.get("draft")
            if draft is not None:
                details = f"{details} | draft: {draft}"
        body = one_line(issue.get("body"), fallback="", limit=180)
        if body:
            details = f"{details} | body: {body}"
        items.append(
            item_record(
                item_id=item_id,
                source="github",
                kind=github_kind,
                title=one_line(issue.get("title"), fallback=f"GitHub {'PR' if is_pr else 'issue'} #{number}"),
                source_created_at=issue.get("created_at"),
                source_updated_at=issue.get("updated_at"),
                source_state=issue.get("state", "unknown"),
                details=details,
                url=issue.get("html_url"),
                artifact_refs=[artifact],
                run_id=run_id,
            )
        )
    return items


def normalize_store_items(store_dir: pathlib.Path, *, state_dir: pathlib.Path, run_dir: pathlib.Path, run_id: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []

    ios_feedback = maybe_read_json(store_dir / "ios" / "feedback.json").get("data") or []
    ios_crashes = maybe_read_json(store_dir / "ios" / "crashes.json").get("data") or []
    android_reviews = maybe_read_json(store_dir / "android" / "reviews.json").get("reviews") or []
    android_metadata = maybe_read_json(store_dir / "android" / "metadata.json")

    feedback_artifact = rel_to_state(store_dir / "ios" / "feedback.json", state_dir)
    for row in ios_feedback:
        attrs = row.get("attributes") or {}
        row_id = row.get("id", "unknown")
        screenshots = [
            rel_to_state(store_dir / path, state_dir)
            for path in attrs.get("downloadedScreenshotPaths") or []
        ]
        items.append(
            item_record(
                item_id=f"testflight:feedback:{row_id}",
                source="testflight",
                kind="feedback",
                title=one_line(attrs.get("comment"), fallback=f"TestFlight feedback {row_id}"),
                source_created_at=attrs.get("createdDate"),
                source_updated_at=attrs.get("createdDate"),
                source_state="submitted",
                details=(
                    f"device: {attrs.get('deviceModel', 'unknown')} | "
                    f"os: iOS {attrs.get('osVersion', 'unknown')} | "
                    f"build: {attrs.get('appVersion') or attrs.get('buildVersion') or 'unknown'}"
                ),
                url=None,
                artifact_refs=[feedback_artifact, *screenshots],
                run_id=run_id,
            )
        )

    crash_artifact = rel_to_state(store_dir / "ios" / "crashes.json", state_dir)
    for row in ios_crashes:
        attrs = row.get("attributes") or {}
        row_id = row.get("id", "unknown")
        refs = [crash_artifact]
        if row.get("crashLogPath"):
            refs.append(rel_to_state(store_dir / row["crashLogPath"], state_dir))
        if row.get("crashLogTextPath"):
            refs.append(rel_to_state(store_dir / row["crashLogTextPath"], state_dir))
        log_status = row.get("crashLogStatus", "unknown")
        if row.get("crashLogError"):
            log_status = f"unavailable: {one_line(row.get('crashLogError'), fallback='unknown error', limit=80)}"
        items.append(
            item_record(
                item_id=f"testflight:crash:{row_id}",
                source="testflight",
                kind="crash",
                title=one_line(attrs.get("comment"), fallback=f"TestFlight crash {row_id}"),
                source_created_at=attrs.get("createdDate"),
                source_updated_at=attrs.get("createdDate"),
                source_state="submitted",
                details=(
                    f"device: {attrs.get('deviceModel', 'unknown')} | "
                    f"os: iOS {attrs.get('osVersion', 'unknown')} | "
                    f"build: {attrs.get('appVersion') or attrs.get('buildVersion') or 'unknown'} | "
                    f"crash log: {log_status}"
                ),
                url=None,
                artifact_refs=refs,
                run_id=run_id,
            )
        )

    review_artifact = rel_to_state(store_dir / "android" / "reviews.json", state_dir)
    for review in android_reviews:
        comment = first_user_comment(review)
        review_id = review.get("reviewId", "unknown")
        rating = comment.get("starRating", "unknown")
        items.append(
            item_record(
                item_id=f"play:review:{review_id}",
                source="play",
                kind="review",
                title=one_line(comment.get("text"), fallback=f"Play review {review_id}"),
                source_created_at=review.get("normalizedLastModified"),
                source_updated_at=review.get("normalizedLastModified"),
                source_state="submitted",
                details=(
                    f"rating: {rating} | "
                    f"app version: {comment.get('appVersionName', 'unknown')} | "
                    f"device: {comment.get('device', 'unknown')}"
                ),
                url=None,
                artifact_refs=[review_artifact],
                run_id=run_id,
            )
        )

    issue_refs = [
        rel_to_state(store_dir / "android" / "error-issues.json", state_dir),
        rel_to_state(store_dir / "android" / "error-reports.json", state_dir),
    ]
    for issue in android_metadata.get("summarizedIssues") or []:
        issue_id = issue.get("issueId", "unknown")
        details = (
            f"location: {issue.get('location', 'unknown')} | "
            f"reports: {issue.get('errorReportCount', 0)} | "
            f"raw reports: {issue.get('rawReportCount', 0)} | "
            f"users: {issue.get('distinctUsers', 'unknown')}"
        )
        if issue.get("sampleReportFirstLine"):
            details += f" | sample: {one_line(issue.get('sampleReportFirstLine'), fallback='', limit=120)}"
        items.append(
            item_record(
                item_id=f"play:crash-issue:{issue_id}",
                source="play",
                kind="crash-issue",
                title=one_line(issue.get("cause"), fallback=f"Play crash issue {issue_id}"),
                source_created_at=None,
                source_updated_at=issue.get("lastErrorReportTime"),
                source_state="open",
                details=details,
                url=issue.get("issueUri"),
                artifact_refs=issue_refs,
                run_id=run_id,
            )
        )

    return items


def default_status_for(item: dict[str, Any]) -> str:
    if item["source"] == "github" and item.get("sourceState") == "closed":
        return "done"
    return "new"


def merge_items(state: dict[str, Any], incoming_items: list[dict[str, Any]], *, run_id: str) -> dict[str, int]:
    now = iso_now()
    items = state.setdefault("items", {})
    counts = {"seen": len(incoming_items), "created": 0, "known": 0, "autoDone": 0}
    for incoming in incoming_items:
        item_id = incoming["id"]
        existing = items.get(item_id)
        if not existing:
            existing = {
                **incoming,
                "status": default_status_for(incoming),
                "priority": "unset",
                "owner": "",
                "resolution": "",
                "notes": [],
                "firstSeenAtUtc": now,
                "lastSeenAtUtc": now,
                "seenCount": 0,
                "history": [],
            }
            items[item_id] = existing
            counts["created"] += 1
        else:
            counts["known"] += 1
            for key, value in incoming.items():
                existing[key] = value
            existing.setdefault("notes", [])
            existing.setdefault("history", [])
            existing.setdefault("priority", "unset")
            existing.setdefault("owner", "")
            existing.setdefault("resolution", "")
            existing.setdefault("firstSeenAtUtc", now)

        existing["lastSeenAtUtc"] = now
        existing["seenCount"] = int(existing.get("seenCount") or 0) + 1
        existing["lastRunId"] = run_id
        existing["history"].append({"atUtc": now, "event": "seen", "runId": run_id})
        existing["history"] = existing["history"][-50:]

        if (
            incoming["source"] == "github"
            and incoming.get("sourceState") == "closed"
            and existing.get("status") in ACTIVE_STATUSES
        ):
            existing["status"] = "done"
            existing["resolution"] = existing.get("resolution") or "closed on GitHub"
            existing["statusSetAtUtc"] = now
            existing["history"].append({"atUtc": now, "event": "auto-marked-done", "runId": run_id})
            counts["autoDone"] += 1
    state["latestRunId"] = run_id
    return counts


def markdown_escape(value: Any) -> str:
    text = str(value if value is not None else "")
    return text.replace("\n", " ").replace("|", "\\|")


def short(value: Any, limit: int = 84) -> str:
    text = markdown_escape(value)
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "..."


def link_for(item: dict[str, Any]) -> str:
    url = item.get("url")
    if url:
        return f"[link]({url})"
    refs = item.get("artifactRefs") or []
    if refs:
        return f"`{refs[0]}`"
    return ""


def sorted_items(state: dict[str, Any]) -> list[dict[str, Any]]:
    return sorted(
        state.get("items", {}).values(),
        key=lambda item: (
            item.get("status") in ACTIVE_STATUSES,
            item.get("sourceUpdatedAt") or item.get("lastSeenAtUtc") or "",
            item.get("id") or "",
        ),
        reverse=True,
    )


def render_table(items: list[dict[str, Any]]) -> list[str]:
    if not items:
        return ["_None._", ""]
    lines = [
        "| ID | Status | Pri | Source | Updated | Seen | Title | Link |",
        "|---|---:|---:|---|---|---:|---|---|",
    ]
    for item in items:
        lines.append(
            "| "
            + " | ".join(
                [
                    f"`{markdown_escape(item.get('id'))}`",
                    markdown_escape(item.get("status", "")),
                    markdown_escape(item.get("priority", "unset")),
                    f"{markdown_escape(item.get('source'))}/{markdown_escape(item.get('kind'))}",
                    markdown_escape(item.get("sourceUpdatedAt") or item.get("lastSeenAtUtc") or ""),
                    markdown_escape(item.get("seenCount", 0)),
                    short(item.get("title"), 100),
                    link_for(item),
                ]
            )
            + " |"
        )
    lines.append("")
    return lines


def render_board(state_dir: pathlib.Path, state: dict[str, Any], latest_run: dict[str, Any] | None = None) -> None:
    _, board_path = state_paths(state_dir)
    items = sorted_items(state)
    active = [item for item in items if item.get("status") in ACTIVE_STATUSES]
    final_recent = [
        item
        for item in items
        if item.get("status") in FINAL_STATUSES and item.get("lastRunId") == state.get("latestRunId")
    ]
    counts: dict[str, int] = {}
    for item in items:
        counts[item.get("status", "unknown")] = counts.get(item.get("status", "unknown"), 0) + 1

    lines = [
        "# Mobile Feedback Triage",
        "",
        f"- State file: `{state_paths(state_dir)[0]}`",
        f"- Updated UTC: `{state.get('updatedAtUtc', '')}`",
        f"- Latest run: `{state.get('latestRunId') or 'none'}`",
        f"- Counts: "
        + ", ".join(f"`{status}` {counts.get(status, 0)}" for status in STATUSES),
        "",
        "## Active Items",
        "",
        *render_table(active),
        "## Handled Seen In Latest Run",
        "",
        *render_table(final_recent),
        "## Marking",
        "",
        "```bash",
        "./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status triaging --owner sigkitten",
        "./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status done --note 'Fixed in <commit-or-version>'",
        "./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status pr-open --note 'Fix PR #<number>'",
        "./tools/scripts/triage-mobile-feedback.py list --status active",
        "```",
        "",
    ]
    if latest_run:
        lines.extend(
            [
                "## Latest Raw Artifacts",
                "",
                f"- Run dir: `{latest_run.get('runDir')}`",
                f"- Store dir: `{latest_run.get('storeDir') or 'skipped'}`",
                f"- GitHub issues: `{latest_run.get('githubIssuesPath') or 'skipped'}`",
                "",
            ]
        )
    board_path.write_text("\n".join(lines).rstrip() + "\n")


def run_store_fetch(args: argparse.Namespace, *, run_dir: pathlib.Path, since: dt.datetime, until: dt.datetime) -> pathlib.Path | None:
    if args.skip_store:
        return None
    if args.store_artifacts_dir:
        return pathlib.Path(args.store_artifacts_dir).expanduser().resolve()
    fetcher = pathlib.Path(args.fetcher).expanduser().resolve()
    if not fetcher.exists():
        raise ScriptError(f"Store fetcher not found: {fetcher}")
    store_dir = ensure_dir(run_dir / "store")
    command = [
        sys.executable,
        str(fetcher),
        "--since",
        since.isoformat().replace("+00:00", "Z"),
        "--until",
        until.isoformat().replace("+00:00", "Z"),
        "--output-dir",
        str(store_dir),
    ]
    passthrough_flags = [
        "skip_ios",
        "skip_android",
        "no_download_ios_screenshots",
    ]
    passthrough_values = [
        "ios_bundle_id",
        "android_package",
        "ios_version",
        "asc_bin",
        "play_service_account_json",
        "play_env_file",
    ]
    for name in passthrough_flags:
        if getattr(args, name):
            command.append("--" + name.replace("_", "-"))
    for name in passthrough_values:
        value = getattr(args, name)
        if value:
            command.extend(["--" + name.replace("_", "-"), value])
    completed = run_command(command)
    (run_dir / "store-fetcher.stdout.md").write_text(completed.stdout)
    (run_dir / "store-fetcher.stderr.txt").write_text(completed.stderr)
    return store_dir


def run_mode(args: argparse.Namespace) -> int:
    state_dir = ensure_dir(pathlib.Path(args.state_dir).expanduser())
    since, until = compute_window(args)
    run_id = dt.datetime.now(tz=UTC).strftime("%Y%m%dT%H%M%SZ")
    run_dir = ensure_dir(state_dir / "runs" / run_id)

    state = load_state(state_dir)
    incoming_items: list[dict[str, Any]] = []

    store_dir = run_store_fetch(args, run_dir=run_dir, since=since, until=until)
    if store_dir:
        incoming_items.extend(normalize_store_items(store_dir, state_dir=state_dir, run_dir=run_dir, run_id=run_id))

    github_issues_path = None
    if not args.skip_github:
        repo = args.github_repo or infer_github_repo()
        token = args.github_token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        github_payload = fetch_github_issues(
            repo=repo,
            token=token,
            since=since,
            until=until,
            open_backfill=not args.no_github_open_backfill,
            output_dir=run_dir,
        )
        github_issues_path = run_dir / "github" / "issues.json"
        incoming_items.extend(
            normalize_github_items(github_payload, state_dir=state_dir, run_dir=run_dir, run_id=run_id)
        )

    counts = merge_items(state, incoming_items, run_id=run_id)
    latest_run = {
        "runId": run_id,
        "runDir": rel_to_state(run_dir, state_dir),
        "storeDir": rel_to_state(store_dir, state_dir) if store_dir else None,
        "githubIssuesPath": rel_to_state(github_issues_path, state_dir) if github_issues_path else None,
        "windowUtc": {
            "since": since.isoformat().replace("+00:00", "Z"),
            "until": until.isoformat().replace("+00:00", "Z"),
        },
        "counts": counts,
    }
    write_json(run_dir / "run.json", latest_run)
    save_state(state_dir, state)
    render_board(state_dir, state, latest_run)

    _, board_path = state_paths(state_dir)
    active_count = sum(1 for item in state["items"].values() if item.get("status") in ACTIVE_STATUSES)
    print(f"Run {run_id}: seen {counts['seen']}, new {counts['created']}, known {counts['known']}, active {active_count}")
    print(f"Board: {board_path}")
    print(f"State: {state_paths(state_dir)[0]}")
    return 0


def mark_mode(args: argparse.Namespace) -> int:
    state_dir = ensure_dir(pathlib.Path(args.state_dir).expanduser())
    state = load_state(state_dir)
    now = iso_now()
    missing = [item_id for item_id in args.item_ids if item_id not in state.get("items", {})]
    if missing:
        raise ScriptError("Unknown item ID(s): " + ", ".join(missing))
    for item_id in args.item_ids:
        item = state["items"][item_id]
        item["status"] = args.status
        item["statusSetAtUtc"] = now
        if args.owner is not None:
            item["owner"] = args.owner
        if args.priority is not None:
            item["priority"] = args.priority
        if args.resolution is not None:
            item["resolution"] = args.resolution
        if args.note:
            item.setdefault("notes", []).append({"atUtc": now, "text": args.note})
        item.setdefault("history", []).append({"atUtc": now, "event": f"marked-{args.status}"})
        item["history"] = item["history"][-50:]
    save_state(state_dir, state)
    render_board(state_dir, state)
    _, board_path = state_paths(state_dir)
    print(f"Marked {len(args.item_ids)} item(s) as {args.status}")
    print(f"Board: {board_path}")
    return 0


def list_mode(args: argparse.Namespace) -> int:
    state = load_state(pathlib.Path(args.state_dir).expanduser())
    items = sorted_items(state)
    if args.status == "active":
        items = [item for item in items if item.get("status") in ACTIVE_STATUSES]
    elif args.status != "all":
        items = [item for item in items if item.get("status") == args.status]
    if args.source:
        items = [item for item in items if item.get("source") == args.source]
    for item in items:
        print(
            f"{item.get('id')} [{item.get('status')}] "
            f"{item.get('source')}/{item.get('kind')} "
            f"{item.get('sourceUpdatedAt') or item.get('lastSeenAtUtc')}: {item.get('title')}"
        )
    return 0


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.command == "run":
        return run_mode(args)
    if args.command == "mark":
        return mark_mode(args)
    if args.command == "list":
        return list_mode(args)
    raise ScriptError(f"Unknown command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ScriptError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
