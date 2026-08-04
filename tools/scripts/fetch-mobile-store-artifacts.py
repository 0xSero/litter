#!/usr/bin/env python3
"""
Fetch mobile store feedback/crash artifacts for a requested timeframe.

Outputs:
  - JSON artifacts under the requested output directory
  - Downloaded iOS TestFlight screenshots
  - Downloaded iOS crash logs when ASC exposes them
  - A Markdown summary describing what was fetched and what was unavailable

Notes:
  - Android private testing feedback is not exposed via the public Google Play
    APIs used here. This script fetches Play reviews plus Play Developer
    Reporting crash issues/reports.
  - Google Play Developer Reporting time windows are hour-aligned UTC. The
    script expands the API interval to whole hours, then filters the payload
    back down to the exact requested window client-side.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


UTC = dt.timezone.utc

DEFAULT_IOS_BUNDLE_ID = "com.sigkitten.litter"
DEFAULT_ANDROID_PACKAGE = "com.sigkitten.litter.android"
DEFAULT_OUTPUT_BASE = pathlib.Path("/tmp/mobile-store-artifacts")
DEFAULT_PLAY_ENV_FILE = pathlib.Path.home() / ".config/litter/play-upload.env"

PLAY_REPORTING_SCOPE = "https://www.googleapis.com/auth/playdeveloperreporting"
PLAY_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"


class ScriptError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    window = parser.add_mutually_exclusive_group(required=False)
    window.add_argument("--last-hours", type=float, help="Fetch artifacts from the last N hours.")
    window.add_argument("--since", help="ISO-8601 start time. Naive timestamps use the local timezone.")
    parser.add_argument("--until", help="ISO-8601 end time. Defaults to now.")

    parser.add_argument("--output-dir", help="Directory for fetched artifacts.")
    parser.add_argument("--ios-bundle-id", default=DEFAULT_IOS_BUNDLE_ID)
    parser.add_argument("--android-package", default=DEFAULT_ANDROID_PACKAGE)
    parser.add_argument("--ios-version", help="Optional iOS pre-release version filter, e.g. 1.0.4.")
    parser.add_argument("--asc-bin", help="Path to the asc CLI.")
    parser.add_argument("--play-service-account-json", help="Path to a Google Play service account JSON.")
    parser.add_argument("--play-env-file", default=str(DEFAULT_PLAY_ENV_FILE))
    parser.add_argument(
        "--check-play-access",
        action="store_true",
        help="Verify Google Play Publisher API access and exit without fetching artifacts.",
    )
    parser.add_argument("--skip-ios", action="store_true")
    parser.add_argument("--skip-android", action="store_true")
    parser.add_argument("--no-download-ios-screenshots", action="store_true")
    return parser.parse_args()


def iso_now() -> str:
    return dt.datetime.now(tz=UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: str) -> dt.datetime:
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(raw)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.datetime.now().astimezone().tzinfo)
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


def ensure_dir(path: pathlib.Path) -> pathlib.Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def to_json_file(path: pathlib.Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")


def load_export_file(path: pathlib.Path) -> dict[str, str]:
    if not path.exists():
        return {}
    env: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :]
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = shlex.split(value, posix=True)[0] if value.strip() else ""
    return env


def resolve_asc_binary(explicit: str | None) -> str:
    candidates = []
    if explicit:
        candidates.append(explicit)
    env_bin = os.environ.get("ASC_BIN")
    if env_bin:
        candidates.append(env_bin)
    which_asc = shutil_which("asc")
    if which_asc:
        candidates.append(which_asc)
    candidates.extend(
        [
            str(pathlib.Path.home() / "Downloads/Bitrig.app/Contents/Resources/claude-agent/asc"),
            "/Applications/Bitrig.app/Contents/Resources/claude-agent/asc",
            str(pathlib.Path.home() / ".local/bin/asc"),
        ]
    )
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise ScriptError("asc CLI not found. Set --asc-bin or ASC_BIN.")


def shutil_which(binary: str) -> str | None:
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        candidate = pathlib.Path(entry) / binary
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def run(
    argv: list[str],
    *,
    cwd: pathlib.Path | None = None,
    check: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        check=False,
        text=True,
        capture_output=capture_output,
    )
    if check and completed.returncode != 0:
        raise ScriptError(
            f"Command failed ({completed.returncode}): {' '.join(shlex.quote(part) for part in argv)}\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return completed


def asc_json(asc_bin: str, args: list[str]) -> dict[str, Any]:
    command = [asc_bin] + args + ["--output", "json"]
    result = run(command)
    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise ScriptError(
            f"Failed to parse ASC JSON for {' '.join(args)}:\n{result.stdout}\n{result.stderr}"
        ) from exc


def maybe_parse_json(text: str) -> dict[str, Any]:
    if not text.strip():
        return {}
    return json.loads(text)


def within_window(timestamp: str | None, since: dt.datetime, until: dt.datetime) -> bool:
    if not timestamp:
        return False
    parsed = parse_timestamp(timestamp)
    return since <= parsed <= until


def resolve_ios_app_id(asc_bin: str, bundle_id: str) -> str:
    payload = asc_json(asc_bin, ["apps", "list", "--bundle-id", bundle_id, "--limit", "1"])
    data = payload.get("data", [])
    if not data:
        raise ScriptError(f"No App Store Connect app found for bundle ID {bundle_id}")
    return data[0]["id"]


def resolve_ios_pre_release_version_id(asc_bin: str, app_id: str, version: str) -> str:
    payload = asc_json(
        asc_bin,
        ["testflight", "pre-release", "list", "--app", app_id, "--paginate", "--limit", "200"],
    )
    for item in payload.get("data", []):
        if item.get("attributes", {}).get("version") == version:
            return item["id"]
    raise ScriptError(f"iOS pre-release version {version} not found for app {app_id}")


def fetch_ios(
    *,
    asc_bin: str,
    bundle_id: str,
    output_dir: pathlib.Path,
    since: dt.datetime,
    until: dt.datetime,
    version: str | None,
    download_screenshots: bool,
) -> dict[str, Any]:
    ios_dir = ensure_dir(output_dir / "ios")
    crash_logs_dir = ensure_dir(ios_dir / "crash-logs")
    feedback_dir = ensure_dir(ios_dir / "feedback-artifacts")

    app_id = resolve_ios_app_id(asc_bin, bundle_id)
    pre_release_id = None
    if version:
        pre_release_id = resolve_ios_pre_release_version_id(asc_bin, app_id, version)

    feedback_script = pathlib.Path(__file__).resolve().parent / "testflight-feedback.sh"
    feedback_env = os.environ.copy()
    feedback_env.update(
        {
            "ASC_BIN": asc_bin,
            "BUNDLE_ID": bundle_id,
            "OUTPUT_FORMAT": "json",
            "OUTPUT_DIR": str(feedback_dir),
            "DOWNLOAD_SCREENSHOTS": "1" if download_screenshots else "0",
            "SINCE": since.isoformat().replace("+00:00", "Z"),
            "UNTIL": until.isoformat().replace("+00:00", "Z"),
        }
    )
    feedback_args = [str(feedback_script)]
    if version:
        feedback_args.append(version)
    feedback_run = subprocess.run(
        feedback_args,
        check=False,
        text=True,
        capture_output=True,
        env=feedback_env,
    )
    if feedback_run.returncode != 0:
        raise ScriptError(
            f"TestFlight feedback script failed ({feedback_run.returncode}):\n"
            f"stdout:\n{feedback_run.stdout}\n"
            f"stderr:\n{feedback_run.stderr}"
        )
    try:
        feedback_payload = json.loads(feedback_run.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise ScriptError(
            f"Failed to parse testflight-feedback.sh JSON output:\n{feedback_run.stdout}\n{feedback_run.stderr}"
        ) from exc
    feedback_rows = feedback_payload.get("data", [])

    crashes_payload = asc_json(
        asc_bin,
        [
            "testflight",
            "crashes",
            "list",
            "--app",
            app_id,
            "--sort",
            "-createdDate",
            "--limit",
            "200",
            "--paginate",
            *(["--build-pre-release-version", pre_release_id] if pre_release_id else []),
        ],
    )
    crash_rows = [
        row
        for row in crashes_payload.get("data", [])
        if within_window(row.get("attributes", {}).get("createdDate"), since, until)
    ]

    for row in crash_rows:
        submission_id = row.get("id")
        if not submission_id:
            continue
        try:
            log_payload = asc_json(
                asc_bin,
                ["testflight", "crashes", "log", "--submission-id", submission_id],
            )
            row["crashLogStatus"] = "ok"
            row["crashLogPath"] = f"ios/crash-logs/{submission_id}.json"
            to_json_file(crash_logs_dir / f"{submission_id}.json", log_payload)
            log_text = (
                log_payload.get("data", {})
                .get("attributes", {})
                .get("logText")
            )
            if log_text:
                (crash_logs_dir / f"{submission_id}.txt").write_text(log_text)
                row["crashLogTextPath"] = f"ios/crash-logs/{submission_id}.txt"
        except Exception as exc:  # noqa: BLE001
            row["crashLogStatus"] = "error"
            row["crashLogError"] = str(exc)

    result = {
        "bundleId": bundle_id,
        "appId": app_id,
        "preReleaseVersion": version,
        "preReleaseVersionId": pre_release_id,
        "feedbackCount": len(feedback_rows),
        "crashCount": len(crash_rows),
        "feedback": feedback_rows,
        "crashes": crash_rows,
    }
    to_json_file(ios_dir / "feedback.json", {"data": feedback_rows})
    to_json_file(ios_dir / "crashes.json", {"data": crash_rows})
    to_json_file(ios_dir / "metadata.json", result)
    return result


def load_service_account_path(explicit: str | None, env_file: pathlib.Path) -> pathlib.Path:
    if explicit:
        path = pathlib.Path(explicit).expanduser()
        if not path.exists():
            raise ScriptError(f"Google Play service account JSON not found: {path}")
        return path
    env_value = os.environ.get("LITTER_PLAY_SERVICE_ACCOUNT_JSON")
    if env_value:
        path = pathlib.Path(env_value).expanduser()
        if path.exists():
            return path
    file_env = load_export_file(env_file)
    candidate = file_env.get("LITTER_PLAY_SERVICE_ACCOUNT_JSON")
    if candidate:
        path = pathlib.Path(candidate).expanduser()
        if path.exists():
            return path
    raise ScriptError(
        "Google Play service account JSON not found. Set --play-service-account-json, "
        "LITTER_PLAY_SERVICE_ACCOUNT_JSON, or ~/.config/litter/play-upload.env."
    )


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def issue_token(service_account_path: pathlib.Path, scope: str) -> str:
    payload = json.loads(service_account_path.read_text())
    now = int(dt.datetime.now(tz=UTC).timestamp())
    header = {"alg": "RS256", "typ": "JWT"}
    claim = {
        "iss": payload["client_email"],
        "scope": scope,
        "aud": payload["token_uri"],
        "exp": now + 3600,
        "iat": now,
    }
    signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}.{b64url(json.dumps(claim, separators=(',', ':')).encode())}"
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(payload["private_key"])
        key_path = pathlib.Path(handle.name)
    try:
        signature = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
            check=True,
            input=signing_input.encode(),
            capture_output=True,
        ).stdout
    except FileNotFoundError as exc:
        raise ScriptError("openssl is required to issue Google Play access tokens.") from exc
    finally:
        key_path.unlink(missing_ok=True)
    assertion = f"{signing_input}.{b64url(signature)}".encode()
    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion.decode(),
        }
    ).encode()
    request = urllib.request.Request(
        payload["token_uri"],
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            token_payload = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        raise ScriptError(f"Google token exchange failed: {exc.read().decode()}") from exc
    return token_payload["access_token"]


def api_get_json(url: str, bearer_token: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {bearer_token}",
            "Accept": "application/json",
            "User-Agent": "litter-store-fetch/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return maybe_parse_json(response.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        raise ScriptError(f"HTTP {exc.code} for {url}: {body}") from exc


def check_play_access(package_name: str, service_account_path: pathlib.Path) -> None:
    token = issue_token(service_account_path, PLAY_PUBLISHER_SCOPE)
    query = urllib.parse.urlencode({"maxResults": "1"})
    api_get_json(
        f"https://androidpublisher.googleapis.com/androidpublisher/v3/"
        f"applications/{package_name}/reviews?{query}",
        token,
    )


def floor_hour(value: dt.datetime) -> dt.datetime:
    return value.astimezone(UTC).replace(minute=0, second=0, microsecond=0)


def ceil_hour(value: dt.datetime) -> dt.datetime:
    utc_value = value.astimezone(UTC)
    floored = floor_hour(utc_value)
    if floored == utc_value.replace(microsecond=0):
        return floored
    return floored + dt.timedelta(hours=1)


def build_play_interval_params(since: dt.datetime, until: dt.datetime) -> dict[str, str]:
    start = floor_hour(since)
    end = ceil_hour(until)
    return {
        "interval.startTime.year": str(start.year),
        "interval.startTime.month": str(start.month),
        "interval.startTime.day": str(start.day),
        "interval.startTime.hours": str(start.hour),
        "interval.endTime.year": str(end.year),
        "interval.endTime.month": str(end.month),
        "interval.endTime.day": str(end.day),
        "interval.endTime.hours": str(end.hour),
    }


def review_last_modified(review: dict[str, Any]) -> str | None:
    comments = review.get("comments") or []
    for comment in reversed(comments):
        user_comment = comment.get("userComment") or {}
        modified = user_comment.get("lastModified") or {}
        seconds = modified.get("seconds")
        if seconds is None:
            continue
        nanos = int(modified.get("nanos", 0))
        stamp = dt.datetime.fromtimestamp(int(seconds), tz=UTC) + dt.timedelta(microseconds=nanos / 1000)
        return stamp.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return None


def fetch_paginated_json(
    *,
    base_url: str,
    bearer_token: str,
    item_key: str,
    query: dict[str, str],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    next_token: str | None = None
    while True:
        params = dict(query)
        if next_token:
            params["pageToken"] = next_token
        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        payload = api_get_json(url, bearer_token)
        rows.extend(payload.get(item_key, []) or [])
        next_token = payload.get("nextPageToken")
        if not next_token:
            break
    return rows


def fetch_android(
    *,
    package_name: str,
    service_account_path: pathlib.Path,
    output_dir: pathlib.Path,
    since: dt.datetime,
    until: dt.datetime,
) -> dict[str, Any]:
    android_dir = ensure_dir(output_dir / "android")
    publisher_token = issue_token(service_account_path, PLAY_PUBLISHER_SCOPE)
    reporting_token = issue_token(service_account_path, PLAY_REPORTING_SCOPE)

    reviews = fetch_paginated_json(
        base_url=f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{package_name}/reviews",
        bearer_token=publisher_token,
        item_key="reviews",
        query={"maxResults": "100"},
    )
    filtered_reviews = []
    for review in reviews:
        modified = review_last_modified(review)
        if modified and within_window(modified, since, until):
            review["normalizedLastModified"] = modified
            filtered_reviews.append(review)

    interval_query = build_play_interval_params(since, until)
    issues = fetch_paginated_json(
        base_url=f"https://playdeveloperreporting.googleapis.com/v1beta1/apps/{package_name}/errorIssues:search",
        bearer_token=reporting_token,
        item_key="errorIssues",
        query={**interval_query, "pageSize": "100"},
    )
    reports = fetch_paginated_json(
        base_url=f"https://playdeveloperreporting.googleapis.com/v1beta1/apps/{package_name}/errorReports:search",
        bearer_token=reporting_token,
        item_key="errorReports",
        query={**interval_query, "pageSize": "100"},
    )

    filtered_issues = [
        row for row in issues if within_window(row.get("lastErrorReportTime"), since, until)
    ]
    filtered_reports = [
        row for row in reports if within_window(row.get("eventTime"), since, until)
    ]

    issue_index = {
        row["name"].split("/")[-1]: row
        for row in filtered_issues
        if row.get("name")
    }
    grouped_reports: dict[str, list[dict[str, Any]]] = {}
    for report in filtered_reports:
        issue_name = report.get("issue", "")
        issue_id = issue_name.split("/")[-1] if issue_name else "unknown"
        grouped_reports.setdefault(issue_id, []).append(report)

    summarized_issues = []
    for issue_id, issue in issue_index.items():
        sample_reports = grouped_reports.get(issue_id, [])
        summarized_issues.append(
            {
                "issueId": issue_id,
                "type": issue.get("type"),
                "cause": issue.get("cause"),
                "location": issue.get("location"),
                "errorReportCount": issue.get("errorReportCount"),
                "distinctUsers": issue.get("distinctUsers"),
                "lastErrorReportTime": issue.get("lastErrorReportTime"),
                "firstAppVersion": issue.get("firstAppVersion"),
                "lastAppVersion": issue.get("lastAppVersion"),
                "issueUri": issue.get("issueUri"),
                "rawReportCount": len(sample_reports),
                "sampleReportFirstLine": (
                    sample_reports[0].get("reportText", "").splitlines()[0]
                    if sample_reports
                    else None
                ),
                "sampleDevices": sorted(
                    {
                        report.get("deviceModel", {}).get("marketingName")
                        for report in sample_reports
                        if report.get("deviceModel", {}).get("marketingName")
                    }
                ),
            }
        )
    summarized_issues.sort(key=lambda row: row.get("lastErrorReportTime") or "", reverse=True)

    result = {
        "packageName": package_name,
        "serviceAccountJson": str(service_account_path),
        "privateTestingFeedbackAvailableViaApi": False,
        "privateTestingFeedbackNote": (
            "Google Play private testing feedback is available in Play Console UI, "
            "not the public APIs used by this script."
        ),
        "reviewCount": len(filtered_reviews),
        "crashIssueCount": len(filtered_issues),
        "crashReportCount": len(filtered_reports),
        "reviews": filtered_reviews,
        "errorIssues": filtered_issues,
        "errorReports": filtered_reports,
        "summarizedIssues": summarized_issues,
    }
    to_json_file(android_dir / "reviews.json", {"reviews": filtered_reviews})
    to_json_file(android_dir / "error-issues.json", {"errorIssues": filtered_issues})
    to_json_file(android_dir / "error-reports.json", {"errorReports": filtered_reports})
    to_json_file(android_dir / "metadata.json", result)
    return result


def render_summary(
    *,
    output_dir: pathlib.Path,
    requested_since: dt.datetime,
    requested_until: dt.datetime,
    ios_result: dict[str, Any] | None,
    android_result: dict[str, Any] | None,
) -> str:
    def md_link(label: str, target: pathlib.Path | str | None) -> str:
        if not target:
            return label
        path = pathlib.Path(target).expanduser() if not str(target).startswith("http") else None
        if path is not None and not path.is_absolute():
            path = output_dir / path
        destination = str(path) if path is not None else str(target)
        return f"[{label}]({destination})"

    def code(value: Any) -> str:
        return f"`{value}`"

    def rel_json(path: str) -> str:
        return md_link(path, output_dir / path)

    def rel_artifact(path: str | None) -> str | None:
        if not path:
            return None
        artifact_path = pathlib.Path(path).expanduser()
        if artifact_path.is_absolute():
            try:
                artifact_path = artifact_path.relative_to(output_dir)
            except ValueError:
                pass
        return md_link(artifact_path.name, output_dir / artifact_path)

    lines = [
        "# Mobile Store Artifacts",
        "",
        f"- Requested window UTC: {code(requested_since.isoformat().replace('+00:00', 'Z'))} to {code(requested_until.isoformat().replace('+00:00', 'Z'))}",
        f"- Generated at UTC: {code(iso_now())}",
        f"- Output dir: {md_link(str(output_dir), output_dir)}",
        f"- Summary file: {md_link('summary.md', output_dir / 'summary.md')}",
        f"- Metadata file: {md_link('metadata.json', output_dir / 'metadata.json')}",
        "",
    ]
    if ios_result is not None:
        lines.extend(
            [
                "## iOS TestFlight",
                "",
                f"- Bundle ID: {code(ios_result['bundleId'])}",
                f"- App ID: {code(ios_result['appId'])}",
                f"- Feedback rows: {code(ios_result['feedbackCount'])}",
                f"- Crash rows: {code(ios_result['crashCount'])}",
                f"- Feedback JSON: {rel_json('ios/feedback.json')}",
                f"- Crash JSON: {rel_json('ios/crashes.json')}",
                f"- Metadata JSON: {rel_json('ios/metadata.json')}",
                "",
            ]
        )
        if ios_result["feedback"]:
            lines.extend(["### iOS Feedback", ""])
            for row in ios_result["feedback"]:
                attrs = row.get("attributes", {})
                created = attrs.get("createdDate", "unknown")
                device_model = attrs.get("deviceModel", "unknown")
                os_version = attrs.get("osVersion", "unknown")
                comment = (attrs.get("comment") or "").strip()
                lines.append(
                    f"- {code(created)} {code(row.get('id', 'unknown'))} {code(device_model)} iOS {code(os_version)}"
                )
                if comment:
                    lines.append(f"  comment: {comment}")
                screenshots = attrs.get("downloadedScreenshotPaths") or []
                if screenshots:
                    links = ", ".join(link for path in screenshots if (link := rel_artifact(path)))
                    lines.append(f"  screenshots: {links}")
                elif attrs.get("screenshots"):
                    remote_links = ", ".join(
                        md_link(f"screenshot-{index+1}", shot.get("url"))
                        for index, shot in enumerate(attrs.get("screenshots") or [])
                        if shot.get("url")
                    )
                    if remote_links:
                        lines.append(f"  screenshot urls: {remote_links}")
            lines.append("")
        if ios_result["crashes"]:
            lines.extend(["### iOS Crashes", ""])
            for row in ios_result["crashes"]:
                attrs = row.get("attributes", {})
                created = attrs.get("createdDate", "unknown")
                comment = (attrs.get("comment") or "").strip()
                device_model = attrs.get("deviceModel", "unknown")
                os_version = attrs.get("osVersion", "unknown")
                version_string = attrs.get("appVersion") or attrs.get("buildVersion") or "unknown"
                lines.append(
                    f"- {code(created)} {code(row.get('id', 'unknown'))} {code(device_model)} iOS {code(os_version)} build {code(version_string)}"
                )
                if comment:
                    lines.append(f"  comment: {comment}")
                if row.get("crashLogPath"):
                    links = [md_link("log.json", output_dir / row["crashLogPath"])]
                    if row.get("crashLogTextPath"):
                        links.append(md_link("log.txt", output_dir / row["crashLogTextPath"]))
                    lines.append(f"  artifacts: {', '.join(links)}")
                elif row.get("crashLogError"):
                    lines.append(f"  crash log: unavailable ({row['crashLogError']})")
            lines.append("")
    if android_result is not None:
        lines.extend(
            [
                "## Android Play",
                "",
                f"- Package: {code(android_result['packageName'])}",
                f"- Reviews in window: {code(android_result['reviewCount'])}",
                f"- Crash issues in window: {code(android_result['crashIssueCount'])}",
                f"- Raw crash reports in window: {code(android_result['crashReportCount'])}",
                f"- Reviews JSON: {rel_json('android/reviews.json')}",
                f"- Crash issues JSON: {rel_json('android/error-issues.json')}",
                f"- Crash reports JSON: {rel_json('android/error-reports.json')}",
                f"- Metadata JSON: {rel_json('android/metadata.json')}",
                "- Private testing feedback screenshots are not available via the public Google Play APIs used here.",
                "",
            ]
        )
        if android_result["reviews"]:
            lines.extend(["### Android Reviews", ""])
            for review in android_result["reviews"]:
                review_id = review.get("reviewId", "unknown")
                modified = review.get("normalizedLastModified", "unknown")
                comment_text = ""
                comments = review.get("comments") or []
                for comment in reversed(comments):
                    user_comment = comment.get("userComment") or {}
                    text = (user_comment.get("text") or "").strip()
                    if text:
                        comment_text = text
                        break
                lines.append(f"- {code(modified)} {code(review_id)}")
                if comment_text:
                    lines.append(f"  comment: {comment_text}")
            lines.append("")
        if android_result["summarizedIssues"]:
            lines.extend(["### Android Crash Issues", ""])
            for issue in android_result["summarizedIssues"]:
                lines.append(
                    f"- {code(issue.get('lastErrorReportTime', 'unknown'))} {code(issue.get('issueId', 'unknown'))} {issue.get('cause', 'unknown cause')}"
                )
                lines.append(
                    f"  location: {issue.get('location', 'unknown')} | reports: {code(issue.get('errorReportCount', 0))} | raw reports: {code(issue.get('rawReportCount', 0))}"
                )
                if issue.get("sampleDevices"):
                    lines.append(f"  devices: {', '.join(issue['sampleDevices'])}")
                if issue.get("sampleReportFirstLine"):
                    lines.append(f"  sample: {issue['sampleReportFirstLine']}")
                if issue.get("issueUri"):
                    lines.append(f"  play console: {md_link('issue', issue['issueUri'])}")
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    args = parse_args()
    if args.check_play_access:
        if args.skip_android:
            raise ScriptError("--check-play-access cannot be combined with --skip-android.")
        service_account_path = load_service_account_path(
            args.play_service_account_json,
            pathlib.Path(args.play_env_file).expanduser(),
        )
        check_play_access(args.android_package, service_account_path)
        print(f"Google Play Publisher API access verified for {args.android_package}.")
        return 0

    if args.skip_ios and args.skip_android:
        raise ScriptError("Nothing to do: both --skip-ios and --skip-android were set.")

    since, until = compute_window(args)
    timestamp = dt.datetime.now(tz=UTC).strftime("%Y%m%dT%H%M%SZ")
    output_dir = pathlib.Path(args.output_dir).expanduser() if args.output_dir else DEFAULT_OUTPUT_BASE / timestamp
    ensure_dir(output_dir)

    metadata = {
        "requestedWindowUtc": {
            "since": since.isoformat().replace("+00:00", "Z"),
            "until": until.isoformat().replace("+00:00", "Z"),
        },
        "generatedAtUtc": iso_now(),
        "outputDir": str(output_dir),
        "ios": None,
        "android": None,
    }

    ios_result = None
    if not args.skip_ios:
        asc_bin = resolve_asc_binary(args.asc_bin)
        ios_result = fetch_ios(
            asc_bin=asc_bin,
            bundle_id=args.ios_bundle_id,
            output_dir=output_dir,
            since=since,
            until=until,
            version=args.ios_version,
            download_screenshots=not args.no_download_ios_screenshots,
        )
        metadata["ios"] = {
            "bundleId": ios_result["bundleId"],
            "appId": ios_result["appId"],
            "feedbackCount": ios_result["feedbackCount"],
            "crashCount": ios_result["crashCount"],
        }

    android_result = None
    if not args.skip_android:
        service_account_path = load_service_account_path(
            args.play_service_account_json,
            pathlib.Path(args.play_env_file).expanduser(),
        )
        android_result = fetch_android(
            package_name=args.android_package,
            service_account_path=service_account_path,
            output_dir=output_dir,
            since=since,
            until=until,
        )
        metadata["android"] = {
            "packageName": android_result["packageName"],
            "reviewCount": android_result["reviewCount"],
            "crashIssueCount": android_result["crashIssueCount"],
            "crashReportCount": android_result["crashReportCount"],
        }

    summary = render_summary(
        output_dir=output_dir,
        requested_since=since,
        requested_until=until,
        ios_result=ios_result,
        android_result=android_result,
    )
    (output_dir / "summary.md").write_text(summary)
    to_json_file(output_dir / "metadata.json", metadata)

    print(summary, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ScriptError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
