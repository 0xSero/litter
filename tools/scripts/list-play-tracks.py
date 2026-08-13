#!/usr/bin/env python3
"""Read-only Google Play track / versionCode listing.

Primary path keeps the ephemeral (uncommitted draft) edit: create an edit,
fetch its track list, and delete the edit in a ``finally`` block so the edit is
removed on every normal and error path. This tool performs no published-state
changes of any kind: it never publishes bundles, promotes artifacts, updates
track entries, or commits an edit.

Fallback path: when ``Edits.insert`` is rejected with ``403 PERMISSION_DENIED``
(the service account lacks edit permission but may still hold read access),
the tool switches to the read-only ``applications.tracks.releases.list``
method, probing the standard track names (``production``, ``beta``, ``qa``,
``alpha``, and the legacy ``internal`` alias). That direct method excludes
obsolete releases and returns at most 20 releases per track, and it provides no
``userFraction``/staged-rollout fraction, so a ``PUBLISHED`` lifecycle state is
reported as available-on-track only, never as terminal rollout proof.

Output is a single normalized JSON document.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

DEFAULT_PACKAGE = "com.sigkitten.litter.android"
PLAY_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
PLAY_EDITS_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
DIRECT_TRACK_PROBES = ("production", "beta", "qa", "alpha", "internal")
DIRECT_GET_NOTE = (
    "Read-only fallback via applications.tracks.releases.list: excludes obsolete "
    "releases, returns at most 20 releases per track, and exposes no "
    "userFraction/staged-rollout fraction; PUBLISHED means available on the track, "
    "not terminal rollout proof."
)


class PlayApiHttpError(RuntimeError):
    """HTTP error from the Play API, carrying the status code, URL, and body."""

    def __init__(self, code: int, url: str, body: str) -> None:
        self.code = code
        self.url = url
        self.body = body
        super().__init__(f"HTTP {code} for {url}: {body}")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def issue_token(service_account_path: pathlib.Path) -> str:
    """Exchange a service-account JSON for an androidpublisher access token."""
    payload = json.loads(service_account_path.read_text())
    now = int(dt.datetime.now(tz=dt.timezone.utc).timestamp())
    header = {"alg": "RS256", "typ": "JWT"}
    claim = {
        "iss": payload["client_email"],
        "scope": PLAY_PUBLISHER_SCOPE,
        "aud": payload["token_uri"],
        "exp": now + 3600,
        "iat": now,
    }
    signing_input = (
        f"{b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url(json.dumps(claim, separators=(',', ':')).encode())}"
    )
    key_path: pathlib.Path | None = None
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
    finally:
        if key_path is not None:
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
            return json.loads(response.read().decode())["access_token"]
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Google token exchange failed: {exc.read().decode()}") from exc


def api_request_json(
    url: str,
    token: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "litter-list-play-tracks/1.0",
    }
    data: bytes | None = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        raise PlayApiHttpError(exc.code, url, body) from exc


def _to_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def is_permission_denied(exc: PlayApiHttpError) -> bool:
    """True when an edits.insert call was rejected for permission (403)."""
    return exc.code == 403 and "PERMISSION_DENIED" in (exc.body or "")


def map_lifecycle_state(raw_state: str | None) -> str | None:
    """Map a raw releaseLifecycleState to the legacy track status vocabulary.

    Only two exact mappings are defined (DRAFT -> draft, PUBLISHED -> completed).
    Every other state (IN_REVIEW, NOT_APPROVED, APPROVED_NOT_PUBLISHED, ...)
    maps to ``None``; its raw value is preserved verbatim instead and the
    userFraction is unknown (null).
    """
    if raw_state == "DRAFT":
        return "draft"
    if raw_state == "PUBLISHED":
        return "completed"
    return None


def _edit_release_to_common(release: dict[str, Any]) -> dict[str, Any]:
    codes = [
        c for c in (_to_int(v) for v in (release.get("versionCodes") or [])) if c is not None
    ]
    return {
        "name": release.get("name"),
        "versionCodes": codes,
        "status": release.get("status"),
        "userFraction": release.get("userFraction"),
        "releaseLifecycleState": None,
    }


def _direct_release_to_common(release: dict[str, Any]) -> dict[str, Any]:
    codes: list[int] = []
    for artifact in release.get("activeArtifacts") or []:
        code = _to_int(artifact.get("versionCode"))
        if code is not None:
            codes.append(code)
    raw_state = release.get("releaseLifecycleState")
    return {
        "name": release.get("releaseName"),
        "versionCodes": codes,
        "status": map_lifecycle_state(raw_state),
        "userFraction": None,
        "releaseLifecycleState": raw_state,
    }


def list_tracks_direct(package: str, token: str, base_url: str = PLAY_EDITS_BASE) -> dict[str, Any]:
    """Read-only fallback: probe standard tracks via applications.tracks.releases.list.

    Per-track 404 (track does not exist) is recorded separately from a 200 with
    no releases (track exists but is empty). The canonical track name is taken
    from the first release's ``track`` field, falling back to the probed name.
    """
    probes = list(DIRECT_TRACK_PROBES)
    resolved: list[str] = []
    not_found: list[str] = []
    empty: list[str] = []
    tracks: list[dict[str, Any]] = []
    for track in probes:
        url = f"{base_url}/{package}/tracks/{urllib.parse.quote(track, safe='')}/releases"
        try:
            payload = api_request_json(url, token, method="GET")
        except PlayApiHttpError as exc:
            if exc.code == 404:
                not_found.append(track)
                continue
            raise
        releases = payload.get("releases") or []
        if not releases:
            empty.append(track)
            continue
        resolved_name = releases[0].get("track") or track
        resolved.append(resolved_name)
        tracks.append(
            {
                "track": resolved_name,
                "releases": [_direct_release_to_common(r) for r in releases],
            }
        )
    return {
        "source": "direct-get",
        "tracks": tracks,
        "directGet": {
            "probed": probes,
            "resolved": resolved,
            "notFound": not_found,
            "empty": empty,
            "note": DIRECT_GET_NOTE,
        },
    }


def list_tracks(package: str, token: str, base_url: str = PLAY_EDITS_BASE) -> dict[str, Any]:
    """Create an ephemeral edit, read tracks, and delete the edit.

    Falls back to the read-only ``applications.tracks.releases.list`` path only
    when ``edits.insert`` returns 403 PERMISSION_DENIED. The DELETE is issued
    inside ``finally`` so it is attempted on every exit path (normal return and
    any exception, including KeyboardInterrupt).
    """
    edits_url = f"{base_url}/{package}/edits"
    try:
        edit = api_request_json(edits_url, token, method="POST", payload={})
    except PlayApiHttpError as exc:
        if is_permission_denied(exc):
            return list_tracks_direct(package, token, base_url)
        raise
    edit_id = edit.get("id")
    if not edit_id:
        raise RuntimeError("create-edit preflight returned no edit id")
    delete_failure: Exception | None = None
    try:
        tracks_payload = api_request_json(
            f"{edits_url}/{urllib.parse.quote(str(edit_id), safe='')}/tracks",
            token,
            method="GET",
        )
    finally:
        try:
            api_request_json(
                f"{edits_url}/{urllib.parse.quote(str(edit_id), safe='')}",
                token,
                method="DELETE",
            )
        except Exception as exc:  # noqa: BLE001 - preserve original error
            delete_failure = exc
    if delete_failure is not None:
        raise RuntimeError(f"failed to delete ephemeral edit {edit_id}: {delete_failure}") from delete_failure

    tracks: list[dict[str, Any]] = []
    for track in tracks_payload.get("tracks") or []:
        name = track.get("track")
        if not name:
            continue
        tracks.append(
            {
                "track": name,
                "releases": [_edit_release_to_common(r) for r in (track.get("releases") or [])],
            }
        )
    return {"source": "edit", "tracks": tracks, "directGet": None}


def normalize(package: str, result: dict[str, Any], generated_at: str) -> dict[str, Any]:
    source = result.get("source")
    tracks = result.get("tracks") or []
    by_track: dict[str, Any] = {}
    overall_highest: int | None = None
    resolved_tracks: list[str] = []
    for track in tracks:
        name = track.get("track")
        if not name:
            continue
        resolved_tracks.append(name)
        releases: list[dict[str, Any]] = []
        track_highest: int | None = None
        for release in track.get("releases") or []:
            codes = [
                c for c in (release.get("versionCodes") or []) if c is not None
            ]
            for c in codes:
                if overall_highest is None or c > overall_highest:
                    overall_highest = c
                if track_highest is None or c > track_highest:
                    track_highest = c
            releases.append(
                {
                    "name": release.get("name"),
                    "versionCodes": codes,
                    "status": release.get("status"),
                    "userFraction": release.get("userFraction"),
                    "releaseLifecycleState": release.get("releaseLifecycleState"),
                }
            )
        by_track[name] = {
            "releases": releases,
            "highestVersionCode": track_highest,
            "source": source,
        }
    normalized: dict[str, Any] = {
        "packageName": package,
        "generatedAtUtc": generated_at,
        "readOnly": True,
        "source": source,
        "resolvedTracks": resolved_tracks,
        "highestVersionCode": overall_highest,
        "tracks": by_track,
    }
    if result.get("directGet") is not None:
        normalized["directGet"] = result["directGet"]
    return normalized


def _self_test() -> int:
    """Deterministic in-process mock covering edit path, 403 fallback,
    non-403 no-fallback, per-track 404 vs empty, raw-state preservation,
    status mapping, source marker, and null userFraction."""
    import http.server
    import threading

    calls: list[tuple[str, str]] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args: Any) -> None:  # silence
            return

        def _send(self, code: int, obj: Any) -> None:
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _handle(self, method: str) -> None:
            calls.append((method, self.path))
            status, obj = self.server.routes.get(
                (method, self.path), (404, {"error": {"message": "unrouted"}})
            )
            self._send(status, obj)

        def do_POST(self) -> None:
            self._handle("POST")

        def do_GET(self) -> None:
            self._handle("GET")

        def do_DELETE(self) -> None:
            self._handle("DELETE")

    def run(routes: dict[tuple[str, str], tuple[int, Any]], fn: Any) -> Any:
        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        server.routes = routes  # type: ignore[attr-defined]
        calls.clear()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_address[1]}/applications"
        try:
            return fn(base)
        finally:
            server.shutdown()
            server.server_close()

    # Scenario 1: happy edit path (no fallback).
    edit_routes = {
        ("POST", "/applications/com.example/edits"): (200, {"id": "edit-1", "expiryTimeSeconds": "3600"}),
        ("GET", "/applications/com.example/edits/edit-1/tracks"): (200, {
            "kind": "androidpublisher#tracksListResponse",
            "tracks": [
                {"track": "internal", "releases": [
                    {"name": "1", "versionCodes": ["200000253"], "status": "completed", "userFraction": 1.0},
                ]},
                {"track": "production", "releases": [
                    {"name": "1", "versionCodes": ["200000250", "200000249"], "status": "completed"},
                ]},
            ],
        }),
        ("DELETE", "/applications/com.example/edits/edit-1"): (200, {}),
    }
    result = run(edit_routes, lambda b: list_tracks("com.example", "fake-token", base_url=b))
    assert result["source"] == "edit", result
    assert calls == [
        ("POST", "/applications/com.example/edits"),
        ("GET", "/applications/com.example/edits/edit-1/tracks"),
        ("DELETE", "/applications/com.example/edits/edit-1"),
    ], calls
    normalized = normalize("com.example", result, "test")
    assert normalized["source"] == "edit", normalized
    assert normalized["resolvedTracks"] == ["internal", "production"], normalized
    assert normalized["highestVersionCode"] == 200000253, normalized
    assert normalized["tracks"]["production"]["highestVersionCode"] == 200000250, normalized
    assert normalized["tracks"]["production"]["source"] == "edit", normalized
    assert normalized["tracks"]["internal"]["releases"][0]["status"] == "completed", normalized
    assert normalized["tracks"]["internal"]["releases"][0]["userFraction"] == 1.0, normalized
    assert normalized["tracks"]["internal"]["releases"][0]["releaseLifecycleState"] is None, normalized
    assert "directGet" not in normalized, normalized

    # Scenario 2: 403 PERMISSION_DENIED on edits.insert -> direct fallback.
    direct_routes = {
        ("POST", "/applications/com.example/edits"): (403, {
            "error": {"code": 403, "message": "The caller does not have permission", "status": "PERMISSION_DENIED"},
        }),
        ("GET", "/applications/com.example/tracks/production/releases"): (200, {"releases": [
            {"track": "production", "releaseName": "1", "releaseLifecycleState": "PUBLISHED",
             "activeArtifacts": [{"versionCode": 200000250}]},
            {"track": "production", "releaseName": "2", "releaseLifecycleState": "DRAFT",
             "activeArtifacts": [{"versionCode": 200000253}]},
        ]}),
        ("GET", "/applications/com.example/tracks/beta/releases"): (200, {"releases": [
            {"track": "beta", "releaseName": "3", "releaseLifecycleState": "IN_REVIEW",
             "activeArtifacts": [{"versionCode": 200000240}]},
        ]}),
        ("GET", "/applications/com.example/tracks/qa/releases"): (404, {"error": {"message": "not found"}}),
        ("GET", "/applications/com.example/tracks/alpha/releases"): (200, {"releases": []}),
        ("GET", "/applications/com.example/tracks/internal/releases"): (404, {"error": {"message": "not found"}}),
    }
    result = run(direct_routes, lambda b: list_tracks("com.example", "fake-token", base_url=b))
    assert result["source"] == "direct-get", result
    assert ("DELETE", "/applications/com.example/edits/edit-1") not in calls, calls
    assert result["directGet"]["probed"] == ["production", "beta", "qa", "alpha", "internal"], result
    assert result["directGet"]["resolved"] == ["production", "beta"], result
    assert result["directGet"]["notFound"] == ["qa", "internal"], result
    assert result["directGet"]["empty"] == ["alpha"], result
    normalized = normalize("com.example", result, "test")
    assert normalized["source"] == "direct-get", normalized
    assert normalized["resolvedTracks"] == ["production", "beta"], normalized
    assert normalized["highestVersionCode"] == 200000253, normalized
    prod = normalized["tracks"]["production"]
    assert prod["source"] == "direct-get", normalized
    assert [r["releaseLifecycleState"] for r in prod["releases"]] == ["PUBLISHED", "DRAFT"], normalized
    assert [r["status"] for r in prod["releases"]] == ["completed", "draft"], normalized
    assert all(r["userFraction"] is None for r in prod["releases"]), normalized
    beta = normalized["tracks"]["beta"]
    assert beta["releases"][0]["releaseLifecycleState"] == "IN_REVIEW", normalized
    assert beta["releases"][0]["status"] is None, normalized
    assert beta["releases"][0]["userFraction"] is None, normalized
    assert normalized["directGet"]["notFound"] == ["qa", "internal"], normalized
    assert normalized["directGet"]["empty"] == ["alpha"], normalized

    # Scenario 3: non-403 edits.insert error must NOT fall back.
    non403_routes = {
        ("POST", "/applications/com.example/edits"): (500, {"error": {"message": "boom"}}),
    }
    raised = False
    try:
        run(non403_routes, lambda b: list_tracks("com.example", "fake-token", base_url=b))
    except PlayApiHttpError as exc:
        raised = True
        assert exc.code == 500, exc
    assert raised, "expected non-403 edits.insert failure to propagate"
    assert calls == [("POST", "/applications/com.example/edits")], calls

    # Scenario 4: edit path tracks GET 500 -> DELETE still fires in finally.
    fail_get_routes = {
        ("POST", "/applications/com.example/edits"): (200, {"id": "edit-1"}),
        ("GET", "/applications/com.example/edits/edit-1/tracks"): (500, {"error": {"message": "forced"}}),
        ("DELETE", "/applications/com.example/edits/edit-1"): (200, {}),
    }
    raised = False
    try:
        run(fail_get_routes, lambda b: list_tracks("com.example", "fake-token", base_url=b))
    except PlayApiHttpError as exc:
        raised = True
        assert exc.code == 500, exc
    assert raised, "expected tracks GET 500 to propagate"
    assert ("DELETE", "/applications/com.example/edits/edit-1") in calls, calls

    print("self-test: OK (edit path, 403 direct fallback, non-403 no-fallback, "
          "404 vs empty, raw-state, mapping, source, null fraction, resolved names)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", default=os.environ.get("LITTER_PLAY_PACKAGE", DEFAULT_PACKAGE))
    parser.add_argument(
        "--service-account-json",
        default=os.environ.get("LITTER_PLAY_SERVICE_ACCOUNT_JSON", ""),
        help="Path to the Google Play service account JSON (or LITTER_PLAY_SERVICE_ACCOUNT_JSON).",
    )
    parser.add_argument("--output", help="Write normalized JSON to this file instead of stdout.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON.")
    parser.add_argument("--self-test", action="store_true", help="Run the in-process mock test and exit.")
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    if not args.service_account_json:
        raise SystemExit("error: --service-account-json or LITTER_PLAY_SERVICE_ACCOUNT_JSON is required")
    service_account_path = pathlib.Path(args.service_account_json).expanduser()
    if not service_account_path.exists():
        raise SystemExit(f"error: service account JSON not found: {service_account_path}")

    token = issue_token(service_account_path)
    result = list_tracks(args.package, token)
    generated_at = (
        dt.datetime.now(tz=dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    normalized = normalize(args.package, result, generated_at)
    text = json.dumps(normalized, indent=2 if args.pretty else None, sort_keys=True)
    if args.output:
        out_path = pathlib.Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(text + "\n")
        print(f"Wrote {out_path}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
