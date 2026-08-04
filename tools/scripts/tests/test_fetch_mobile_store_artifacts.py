import importlib.util
import io
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock


SCRIPT_PATH = pathlib.Path(__file__).parents[1] / "fetch-mobile-store-artifacts.py"
SPEC = importlib.util.spec_from_file_location("fetch_mobile_store_artifacts", SCRIPT_PATH)
assert SPEC and SPEC.loader
STORE_ARTIFACTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STORE_ARTIFACTS)


class PlayAccessCheckTests(unittest.TestCase):
    def test_check_play_access_creates_and_discards_edit(self) -> None:
        service_account = pathlib.Path("/tmp/service-account.json")
        with (
            mock.patch.object(STORE_ARTIFACTS, "issue_token", return_value="token") as issue_token,
            mock.patch.object(
                STORE_ARTIFACTS,
                "api_request_json",
                side_effect=[{"id": "edit-123"}, {}],
            ) as api_request_json,
        ):
            STORE_ARTIFACTS.check_play_access("com.example.app", service_account)

        issue_token.assert_called_once_with(service_account, STORE_ARTIFACTS.PLAY_PUBLISHER_SCOPE)
        self.assertEqual(
            api_request_json.call_args_list,
            [
                mock.call(
                    "https://androidpublisher.googleapis.com/androidpublisher/v3/"
                    "applications/com.example.app/edits",
                    "token",
                    method="POST",
                    payload={},
                ),
                mock.call(
                    "https://androidpublisher.googleapis.com/androidpublisher/v3/"
                    "applications/com.example.app/edits/edit-123",
                    "token",
                    method="DELETE",
                ),
            ],
        )

    def test_check_play_access_rejects_missing_edit_id(self) -> None:
        service_account = pathlib.Path("/tmp/service-account.json")
        with (
            mock.patch.object(STORE_ARTIFACTS, "issue_token", return_value="token"),
            mock.patch.object(STORE_ARTIFACTS, "api_request_json", return_value={}),
        ):
            with self.assertRaisesRegex(STORE_ARTIFACTS.ScriptError, "no edit ID"):
                STORE_ARTIFACTS.check_play_access("com.example.app", service_account)

    def test_check_only_mode_skips_artifact_fetch(self) -> None:
        with tempfile.NamedTemporaryFile() as service_account:
            argv = [
                str(SCRIPT_PATH),
                "--check-play-access",
                "--play-service-account-json",
                service_account.name,
            ]
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(STORE_ARTIFACTS, "check_play_access") as check_play_access,
                redirect_stdout(io.StringIO()) as stdout,
            ):
                self.assertEqual(STORE_ARTIFACTS.main(), 0)

        check_play_access.assert_called_once()
        self.assertIn("Google Play Publisher API access verified", stdout.getvalue())

    def test_check_only_mode_rejects_skip_android(self) -> None:
        argv = [str(SCRIPT_PATH), "--check-play-access", "--skip-android"]
        with mock.patch.object(sys, "argv", argv):
            with self.assertRaisesRegex(STORE_ARTIFACTS.ScriptError, "cannot be combined"):
                STORE_ARTIFACTS.main()


class ReleasePreflightScriptTests(unittest.TestCase):
    def test_google_play_preflight_rejects_missing_secrets(self) -> None:
        self.assert_missing_secret("check-google-play-release.sh", "ANDROID_UPLOAD_KEYSTORE_B64")

    def test_app_store_preflight_rejects_missing_secrets(self) -> None:
        self.assert_missing_secret("check-app-store-release.sh", "ASC_KEY_ID")

    def assert_missing_secret(self, script_name: str, secret_name: str) -> None:
        with tempfile.TemporaryDirectory() as runner_temp:
            result = subprocess.run(
                [str(SCRIPT_PATH.with_name(script_name))],
                check=False,
                capture_output=True,
                text=True,
                env={"PATH": os.environ["PATH"], "RUNNER_TEMP": runner_temp},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"Missing required secret: {secret_name}", result.stderr)


if __name__ == "__main__":
    unittest.main()
