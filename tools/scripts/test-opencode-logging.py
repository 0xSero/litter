#!/usr/bin/env python3
"""Isolated lifecycle regressions for the rendered remote OpenCode shell scripts.

No SSH, OpenCode installation, model calls, or user HOME mutations. Run on both
macOS and Linux with --shell /bin/sh (and optionally --shell /bin/dash).
"""
import argparse
import os
from pathlib import Path
import shlex
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'shared/rust-bridge/codex-mobile-client/src/ssh_scripts/posix'
SHELL = '/bin/sh'


def eventually(predicate, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError('Expected lifecycle condition was not reached')


def processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat='], text=True)
    return {int(p): (int(parent), state) for p, parent, state in
            (row.split(None, 2) for row in rows.splitlines() if row.strip())}


def alive(pid):
    entry = processes().get(pid)
    return entry is not None and not entry[1].startswith('Z')


class OpenCodeLoggingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='litter-opencode-test-')
        self.home = Path(self.temp.name)
        self.session = self.home / '.litter/sessions/opencode'
        self.pids = set()
        bin_dir = self.home / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'sh').symlink_to(SHELL)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f'{bin_dir}:{os.environ["PATH"]}')
        self.fake = bin_dir / 'fake-opencode'
        self.fake.write_text('#!' + sys.executable + '\n' + '''
import os, time
from pathlib import Path
home = Path(os.environ['HOME'])
mode = os.environ.get('TEST_MODE', 'burst')
if mode == 'fail':
    os.write(2, b'EXPECTED_STARTUP_FAILURE\\n')
    raise SystemExit(7)
if mode == 'descendant':
    child = os.fork()
    if child == 0:
        while True: time.sleep(1)
    (home / 'descendant.pid').write_text(str(child))
if mode in ('burst', 'slow'):
    # Keep the same 256 KiB per stream in both modes. Hundreds of tiny sleeps
    # accumulate VM timer coalescing and turn readiness into a scheduler test.
    chunks, size = (16, 16384) if mode == 'slow' else (256, 1024)
    for _ in range(chunks):
        os.write(1, b'O' * size)
        os.write(2, b'E' * size)
        if mode == 'slow': time.sleep(0.03)
(home / ('ready.' + str(os.getpid()))).write_text('ready')
while not (home / ('exit.' + str(os.getpid()))).exists():
    (home / ('heartbeat.' + str(os.getpid()))).write_text(str(time.monotonic()))
    time.sleep(0.03)
''')
        self.fake.chmod(0o700)

    def tearDown(self):
        if (self.home / 'descendant.pid').exists():
            self.pids.add(int((self.home / 'descendant.pid').read_text()))
        # Capture every private supervisor/server even if an assertion failed.
        for path in self.session.glob('.capture.*/*.pid'):
            try:
                self.pids.add(int(path.read_text()))
            except (OSError, ValueError):
                pass
        family = processes()
        for _ in range(5):
            self.pids.update(p for p, (parent, _) in family.items() if parent in self.pids)
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        time.sleep(0.3)
        for pid in self.pids:
            if alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.temp.cleanup()

    def render(self, name):
        value = (SCRIPTS / name).read_text()
        for key, replacement in {'PROFILE_INIT': '', 'SESSION_ID': 'opencode',
                                 'BIN': shlex.quote(str(self.fake)), 'PORT': '12345'}.items():
            value = value.replace('{{' + key + '}}', replacement)
        self.assertNotIn('{{', value)
        return value

    def run_script(self, name, mode='burst'):
        return subprocess.run([SHELL, '-c', self.render(name)],
                              env=dict(self.env, TEST_MODE=mode),
                              text=True, capture_output=True, timeout=8)

    def launch(self, mode='burst'):
        result = self.run_script('opencode_spawn.sh', mode)
        self.assertEqual(result.returncode, 0, result.stderr)
        pid = int((self.session / 'agent.pid').read_text())
        self.pids.add(pid)
        try:
            eventually(lambda: (self.home / f'ready.{pid}').exists())
        except AssertionError:
            sizes = {name: (self.session / name).stat().st_size
                     for name in ['out.log', 'err.log'] if (self.session / name).is_file()}
            self.fail(f'Producer did not finish: mode={mode}, alive={alive(pid)}, log_bytes={sizes}')
        return pid

    def capture_for(self, pid):
        return next(path.parent for path in self.session.glob('.capture.*/agent.pid')
                    if path.read_text().strip() == str(pid))

    def test_burst_cap_and_persistence_after_launcher_exits_and_hup(self):
        pid = self.launch()
        capture = self.capture_for(pid)
        supervisor = int((capture / 'supervisor.pid').read_text())
        children = {p for p, (parent, _) in processes().items() if parent == supervisor}
        os.kill(supervisor, signal.SIGHUP)
        stamp = self.home / f'heartbeat.{pid}'
        previous = stamp.read_text()
        eventually(lambda: stamp.read_text() != previous)
        for name in ['out.log', 'err.log']:
            self.assertEqual((self.session / name).stat().st_size, 65536)
        result = self.run_script('opencode_cleanup.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        eventually(lambda: not capture.exists())
        eventually(lambda: not alive(pid) and all(not alive(p) for p in children))

    def test_slow_writer_survives_both_caps(self):
        pid = self.launch('slow')
        self.assertTrue(alive(pid))
        self.assertEqual((self.session / 'out.log').stat().st_size, 65536)
        self.assertEqual((self.session / 'err.log').stat().st_size, 65536)

    def test_server_exit_reaps_readers_even_when_descendant_holds_fds(self):
        pid = self.launch('descendant')
        capture = self.capture_for(pid)
        supervisor = int((capture / 'supervisor.pid').read_text())
        children = {p for p, (parent, _) in processes().items() if parent == supervisor}
        (self.home / f'exit.{pid}').touch()
        eventually(lambda: not capture.exists())
        eventually(lambda: all(not alive(p) for p in children))
        self.assertTrue(alive(int((self.home / 'descendant.pid').read_text())))

    def assert_startup_failure(self):
        result = self.run_script('opencode_spawn.sh', 'fail')
        if result.returncode == 0:
            # Process scheduling can put failure beyond the immediate spawn
            # probe; the caller's health stage must report the same diagnostics.
            pid = int((self.session / 'agent.pid').read_text())
            self.pids.add(pid)
            eventually(lambda: not alive(pid))
            result = self.run_script('opencode_health_wait.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('EXPECTED_STARTUP_FAILURE', result.stderr)
        eventually(lambda: not list(self.session.glob('.capture.*')))

    def test_early_failure_keeps_diagnostic_and_cleans_private_helpers(self):
        self.fake.write_text('#!/bin/sh\nprintf "EXPECTED_STARTUP_FAILURE\\n" >&2\nexit 7\n')
        self.assert_startup_failure()

    def test_failure_diagnostic_survives_slow_capture_start(self):
        head = self.home / 'bin/head'
        real_head = shutil.which('head')
        head.write_text('#!' + sys.executable + '\n' +
                        'import os,sys,time\nfrom pathlib import Path\n' +
                        'home=Path(os.environ["HOME"])\n' +
                        'out=home/".litter/sessions/opencode/out.log"\nstream="out" if out.exists() and os.fstat(1).st_ino == out.stat().st_ino else "err"\n' +
                        '(home/("capture-ready-"+stream)).touch()\n' +
                        f'time.sleep(0.15)\nos.execv({real_head!r}, ["head", *sys.argv[1:]])\n')
        head.chmod(0o700)
        # Exclude interpreter startup from the injected150ms read delay.
        self.fake.write_text('#!/bin/sh\nwhile [ ! -f "$HOME/capture-ready-out" ] || [ ! -f "$HOME/capture-ready-err" ]; do sleep 0.005; done\nprintf "EXPECTED_STARTUP_FAILURE\\n" >&2\nexit 7\n')
        self.assert_startup_failure()

    def test_unwritable_log_falls_through_to_drain(self):
        self.session.mkdir(parents=True)
        (self.session / 'out.log').mkdir()
        pid = self.launch()
        self.assertTrue(alive(pid))
        self.assertEqual((self.session / 'err.log').stat().st_size, 65536)

    def test_overlapping_launch_cleanup_does_not_remove_newer_capture(self):
        first = self.launch()
        first_capture = self.capture_for(first)
        second = self.launch()
        second_capture = self.capture_for(second)
        os.kill(first, signal.SIGTERM)
        eventually(lambda: not first_capture.exists())
        self.assertTrue(second_capture.exists())
        self.assertTrue(alive(second))
        self.assertEqual((self.session / 'agent.pid').read_text().strip(), str(second))
        for name in ['out.log', 'err.log']:
            self.assertLessEqual((self.session / name).stat().st_size, 65536)

    def test_broken_head_is_killed_and_reaped_on_server_exit(self):
        head = self.home / 'bin/head'
        head.write_text('#!' + sys.executable + '\n' +
                        'import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nwhile True: time.sleep(1)\n')
        head.chmod(0o700)
        pid = self.launch('quiet')
        capture = self.capture_for(pid)
        supervisor = int((capture / 'supervisor.pid').read_text())
        family = {supervisor}
        for _ in range(4):
            family.update(p for p, (parent, _) in processes().items() if parent in family)
        (self.home / f'exit.{pid}').touch()
        eventually(lambda: not capture.exists())
        eventually(lambda: all(not alive(p) for p in family))

    def test_unsupported_head_still_drains(self):
        head = self.home / 'bin/head'
        head.write_text('#!/bin/sh\nexit 64\n')
        head.chmod(0o700)
        self.assertTrue(alive(self.launch()))

    def test_fifo_setup_failure_cleans_private_helpers(self):
        mkfifo = self.home / 'bin/mkfifo'
        mkfifo.write_text('#!/bin/sh\nexit 1\n')
        mkfifo.chmod(0o700)
        result = self.run_script('opencode_spawn.sh')
        self.assertNotEqual(result.returncode, 0)
        eventually(lambda: not list(self.session.glob('.capture.*')))

    def test_setup_cancellation_reaps_owned_children(self):
        mkfifo = self.home / 'bin/mkfifo'
        real_mkfifo = shutil.which('mkfifo')
        mkfifo.write_text('#!/bin/sh\nkill -TERM "$PPID"\nexec ' +
                          shlex.quote(real_mkfifo) + ' "$@"\n')
        mkfifo.chmod(0o700)
        self.run_script('opencode_spawn.sh')
        eventually(lambda: not list(self.session.glob('.capture.*')))
        pid_file = self.session / 'agent.pid'
        if pid_file.exists():
            pid = int(pid_file.read_text())
            self.pids.add(pid)
            eventually(lambda: not alive(pid))

    def test_pid_publication_failure_stops_owned_server(self):
        render = self.render
        # Fault-inject an IO failure at each publication without changing any
        # global filesystem permissions (also valid when CI runs as root).
        for destination in ['$capture_dir/supervisor.pid', '$capture_dir/agent.pid',
                            '$session_dir/agent.pid']:
            with self.subTest(destination=destination):
                self.render = lambda name, destination=destination: render(name).replace(
                    f'>"{destination}" || exit 1', '>"/dev/null/no-such-file" || exit 1')
                result = self.run_script('opencode_spawn.sh')
                self.assertNotEqual(result.returncode, 0)
                eventually(lambda: not list(self.session.glob('.capture.*')))
        self.render = render

    def test_launcher_exec_failure_removes_private_helper(self):
        nohup = self.home / 'bin/nohup'
        nohup.write_text('#!/bin/sh\nexit 1\n')
        nohup.chmod(0o700)
        result = self.run_script('opencode_spawn.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.session.glob('.capture.*')), [])

    def test_legacy_newline_free_diagnostics_are_byte_bounded(self):
        self.session.mkdir(parents=True)
        for name in ['out.log', 'err.log']:
            (self.session / name).write_bytes(b'X' * (1024 * 1024))
        result = self.run_script('opencode_logs.sh')
        self.assertEqual(result.returncode, 0)
        self.assertLessEqual(len(result.stdout.encode()), 32768 + 200)
        # Health-failure path must use the same byte-before-line bound.
        (self.session / 'agent.pid').write_text('99999999')
        result = self.run_script('opencode_health_wait.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertLessEqual(len(result.stderr.encode()), 32768 + 300)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--shell', default='/bin/sh')
    args, unittest_args = parser.parse_known_args()
    SHELL = str(Path(args.shell).resolve())
    unittest.main(argv=[sys.argv[0], *unittest_args])
