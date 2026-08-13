#!/usr/bin/env python3
"""Read-only Google Play track / versionCode listing.

Reads the current track state for a package by creating an ephemeral
(uncommitted draft) edit, fetching its track list, and deleting the edit.
Deletion is performed in a ``finally`` block so it runs on every normal and
error path. This tool performs no published-state changes of any kind: it
never publishes bundles, promotes artifacts, updates track entries, or
commits an edit.

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
        raise RuntimeError(f"HTTP {exc.code} for {url}: {body}") from exc


def list_tracks(package: str, token: str, base_url: str = PLAY_EDITS_BASE) -> dict[str, Any]:
    """Create an ephemeral edit, read tracks, and delete the edit.

    The DELETE is issued inside ``finally`` so it is attempted on every exit
    path (normal return and any exception, including KeyboardInterrupt).
    """
    edits_url = f"{base_url}/{package}/edits"
    edit = api_request_json(edits_url, token, method="POST", payload={})
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
    return tracks_payload


def _to_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def normalize(package: str, tracks_payload: dict[str, Any], generated_at: str) -> dict[str, Any]:
    tracks = tracks_payload.get("tracks") or []
    by_track: dict[str, Any] = {}
    overall_highest: int | None = None
    for track in tracks:
        name = track.get("track")
        if not name:
            continue
        releases: list[dict[str, Any]] = []
        track_highest: int | None = None
        for release in track.get("releases") or []:
            codes = [
                c
                for c in (_to_int(v) for v in (release.get("versionCodes") or []))
                if c is not None
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
                }
            )
        by_track[name] = {
            "releases": releases,
            "highestVersionCode": track_highest,
        }
    return {
        "packageName": package,
        "generatedAtUtc": generated_at,
        "readOnly": True,
        "highestVersionCode": overall_highest,
        "tracks": by_track,
    }


def _self_test() -> int:
    """In-process mock of the Play API proving create -> GET tracks -> DELETE
    ordering and that DELETE still fires when the tracks GET fails."""
    import http.server
    import threading

    calls: list[tuple[str, str]] = []
    state: dict[str, Any] = {"fail_get": False}

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

        def do_POST(self) -> None:
            calls.append(("POST", self.path))
            if self.path.endswith("/edits"):
                self._send(200, {"id": "edit-1", "expiryTimeSeconds": "3600"})
            else:
                self._send(404, {})

        def do_GET(self) -> None:
            calls.append(("GET", self.path))
            if self.path.endswith("/edits/edit-1/tracks"):
                if state["fail_get"]:
                    self._send(500, {"error": {"message": "forced"}})
                else:
                    self._send(200, {
                        "kind": "androidpublisher#tracksListResponse",
                        "tracks": [
                            {
                                "track": "internal",
                                "releases": [
                                    {"name": "1", "versionCodes": ["200000253"], "status": "completed"},
                                ],
                            },
                            {
                                "track": "production",
                                "releases": [
                                    {"name": "1", "versionCodes": ["200000250", "200000249"], "status": "completed"},
                                ],
                            },
                        ],
                    })
            else:
                self._send(404, {})

        def do_DELETE(self) -> None:
            calls.append(("DELETE", self.path))
            if self.path.endswith("/edits/edit-1"):
                self._send(200, {})
            else:
                self._send(404, {})

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}/applications"
    try:
        # Happy path.
        payload = list_tracks("com.example", "fake-token", base_url=base)
        assert calls[-3:] == [
            ("POST", "/applications/com.example/edits"),
            ("GET", "/applications/com.example/edits/edit-1/tracks"),
            ("DELETE", "/applications/com.example/edits/edit-1"),
        ], f"unexpected call order: {calls[-3:]}"
        normalized = normalize("com.example", payload, "test")
        assert normalized["highestVersionCode"] == 200000253, normalized
        assert normalized["tracks"]["production"]["highestVersionCode"] == 200000250, normalized

        # Error path: GET tracks returns 500; DELETE must still fire in finally.
        calls.clear()
        state["fail_get"] = True
        try:
            list_tracks("com.example", "fake-token", base_url=base)
        except RuntimeError:
            pass
        else:
            raise AssertionError("expected list_tracks to raise on GET 500")
        assert ("POST", "/applications/com.example/edits") in calls, calls
        assert ("DELETE", "/applications/com.example/edits/edit-1") in calls, f"DELETE missing on error path: {calls}"

        print("self-test: OK (create -> GET tracks -> DELETE; DELETE fires on error path)")
        return 0
    finally:
        server.shutdown()
        server.server_close()


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
    tracks_payload = list_tracks(args.package, token)
    generated_at = (
        dt.datetime.now(tz=dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    normalized = normalize(args.package, tracks_payload, generated_at)
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
