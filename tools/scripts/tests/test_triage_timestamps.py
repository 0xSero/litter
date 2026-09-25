import datetime as dt
import importlib.util
import os
import pathlib
import time
import unittest
from unittest import mock


SCRIPTS = pathlib.Path(__file__).parents[1]
MODULES = []
for filename in ("fetch-mobile-store-artifacts.py", "triage-mobile-feedback.py"):
    spec = importlib.util.spec_from_file_location(filename.removesuffix(".py"), SCRIPTS / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    MODULES.append(module)


@unittest.skipUnless(hasattr(time, "tzset"), "requires a configurable local timezone")
class TriageTimestampTests(unittest.TestCase):
    def setUp(self) -> None:
        # POSIX TZ rules make the test independent of installed IANA tzdata.
        self.environment = mock.patch.dict(os.environ, {"TZ": "EST5EDT,M3.2.0,M11.1.0"})
        self.environment.start()
        time.tzset()
        self.addCleanup(self.restore_timezone)

    def restore_timezone(self) -> None:
        self.environment.stop()
        time.tzset()

    def test_naive_dates_use_the_offset_at_the_requested_date(self) -> None:
        for module in MODULES:
            for value, expected in (
                ("2026-01-15T12:00:00", "2026-01-15T17:00:00+00:00"),
                ("2026-07-15T12:00:00", "2026-07-15T16:00:00+00:00"),
            ):
                with self.subTest(script=module.__name__, value=value):
                    self.assertEqual(module.parse_timestamp(value).isoformat(), expected)

    def test_explicit_offsets_are_preserved(self) -> None:
        for module in MODULES:
            for value in ("2026-01-15T12:00:00Z", "2026-01-15T14:00:00+02:00"):
                with self.subTest(script=module.__name__, value=value):
                    self.assertEqual(
                        module.parse_timestamp(value), dt.datetime(2026, 1, 15, 12, tzinfo=dt.timezone.utc)
                    )


if __name__ == "__main__":
    unittest.main()
