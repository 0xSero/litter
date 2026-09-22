#!/usr/bin/env bash
set -euo pipefail

# Measure user-visible interaction latency for Litter.
#
# The app already records the pieces; nothing joined them into a report:
#
#   iOS      `PerfTracker` emits `perf` signposts and `[LLog][*][perf]` lines.
#            `OpenThread` / `SendMessage` intervals pair a tap or a send with
#            the first frame that shows its result.
#   Android  `PerfTrace` writes the same two intervals to the `perf` log tag.
#   Rust     `codex-mobile-client` emits `mobile request timing` events with
#            `elapsed_ms` per server request, plus per-turn `startTurn` timing.
#
# Modes:
#   ios-tests        build + run the XCTest latency suites, then report them
#   ios-log [file]   parse a saved simulator console log (default: newest
#                    under artifacts/ios-sim-run)
#   ios-trace <t>    export `OpenThread` / `SendMessage` intervals from an
#                    `.trace` recorded by `make ios-sim-run`
#   android [serial] frame stats, cold start, and `perf` logcat lines
#   rust [file]      parse Rust `mobile request timing` / `startTurn` lines
#   all              every mode that has an input available right now
#
# Every mode is read-only apart from `ios-tests` and `android`, which drive a
# simulator/device to produce the input they parse.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="$ROOT/apps/ios"
ARTIFACTS_ROOT="$ROOT/artifacts/interaction-latency"
ANDROID_PACKAGE="${ANDROID_PACKAGE:-com.sigkitten.litter.android}"
IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-com.sigkitten.litter}"
IOS_SIM_DEVICE="${IOS_SIM_DEVICE:-iPhone 17 Pro}"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
RUN_DIR="$ARTIFACTS_ROOT/$TIMESTAMP"

mkdir -p "$RUN_DIR"

# Parse `perf` latency lines and XCTest measurements, then print a table.
report() {
  local label="$1" input="$2" out="$3"
  if [[ ! -f "$input" ]]; then
    echo "ERROR: $input does not exist" >&2
    exit 1
  fi
  python3 - "$label" "$input" "$out" <<'PY'
import json, re, statistics, sys

label, in_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(in_path, encoding="utf-8", errors="ignore") as handle:
    text = handle.read()

# `PerfTracker` / `PerfTrace`: "<name> latency key=<key> <ms>ms"
latency = re.compile(r"\b(OpenThread|SendMessage) latency key=(\S+) ([\d.]+)ms")
# `AppModel.startTurn`: "startTurn completed in <ms>ms"
start_turn = re.compile(r"startTurn completed in ([\d.]+)ms")
# Rust `ffi/client.rs`: `elapsed_ms=<n>` next to an `operation="<name>"`.
rust_timing = re.compile(r'operation="([^"]+)".*?elapsed_ms=(\d+)')
# XCTest: `measured [Time, seconds] average: 0.01, ... values: [0.011, 0.012]`
xctest = re.compile(
    r"Test Case '-\[(\S+)\s+(\w+)\]' measured \[Time, seconds\] .*?values: \[([^\]]*)\]"
)

intervals = {}
requests = {}
xctest_rows = {}

for line in text.splitlines():
    for name, key, ms in latency.findall(line):
        intervals.setdefault(name, []).append(float(ms))
    for ms in start_turn.findall(line):
        intervals.setdefault("startTurn", []).append(float(ms))
    for operation, ms in rust_timing.findall(line):
        requests.setdefault(operation, []).append(int(ms))
    for _cls, test, values in xctest.findall(line):
        samples = [float(v) * 1000 for v in values.split(",") if v.strip()]
        if samples:
            xctest_rows.setdefault(test, []).extend(samples)

def stats(samples):
    ordered = sorted(samples)
    return {
        "count": len(ordered),
        "min_ms": round(ordered[0], 2),
        "median_ms": round(statistics.median(ordered), 2),
        "p95_ms": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))], 2),
        "max_ms": round(ordered[-1], 2),
    }

print(f"\n== {label} ==")
payload = {"label": label, "intervals": {}, "requests": {}, "xctest": {}}
if intervals:
    print(f"{'interval':<24} {'n':>4} {'min':>9} {'median':>9} {'p95':>9} {'max':>9}   (ms)")
    for name in sorted(intervals):
        s = stats(intervals[name])
        payload["intervals"][name] = s
        print(f"{name:<24} {s['count']:>4} {s['min_ms']:>9} {s['median_ms']:>9} {s['p95_ms']:>9} {s['max_ms']:>9}")
else:
    print("  no paired intervals found (OpenThread/SendMessage/startTurn)")

if requests:
    print(f"\n{'rust request':<32} {'n':>4} {'median':>9} {'max':>9}   (ms)")
    for operation in sorted(requests):
        s = stats(requests[operation])
        payload["requests"][operation] = s
        print(f"{operation:<32} {s['count']:>4} {s['median_ms']:>9} {s['max_ms']:>9}")

if xctest_rows:
    print(f"\n{'xctest measurement':<56} {'n':>4} {'median':>9}   (ms)")
    for test in sorted(xctest_rows):
        s = stats(xctest_rows[test])
        payload["xctest"][test] = s
        print(f"{test:<56} {s['count']:>4} {s['median_ms']:>9}")

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
print(f"\nwrote {out_path}")
PY
}

parse_log() {
  local input="$1" label="$2" out="$3"
  report "$label" "$input" "$out"
}

booted_sim_udid() {
  xcrun simctl list devices booted -j 2>/dev/null | python3 -c '
import json, sys
for devices in json.load(sys.stdin).get("devices", {}).values():
    for device in devices:
        if device.get("state") == "Booted":
            print(device["udid"])
            raise SystemExit(0)
' 2>/dev/null || true
}

ios_tests() {
  local udid destination
  udid="$(booted_sim_udid)"
  if [[ -n "$udid" ]]; then
    destination="platform=iOS Simulator,id=$udid"
  else
    destination="platform=iOS Simulator,name=$IOS_SIM_DEVICE"
  fi
  echo "==> Running iOS latency suites on $destination"
  echo "    InteractionTimingTests measures the transcript pipeline end to end."
  echo "    The OpenThread/SendMessage intervals need a driven app run:"
  echo "    use 'make ios-sim-run' then '$0 ios-log'."
  local log="$RUN_DIR/ios-xctest.log"
  xcodebuild test \
    -project "$IOS_DIR/Litter.xcodeproj" \
    -scheme "${IOS_SCHEME:-Litter}" \
    -configuration Debug \
    -destination "$destination" \
    -only-testing:LitterTests/InteractionTimingTests \
    -only-testing:LitterTests/PerformanceMeasurementTests \
    2>&1 | tee "$log"
  report "iOS XCTest latency suites" "$log" "$RUN_DIR/ios-xctest.json"
}

ios_log() {
  local input="$1"
  if [[ -z "$input" ]]; then
    input="$(/bin/ls -t "$ROOT"/artifacts/ios-sim-run/*/sim-console.log 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$input" || ! -f "$input" ]]; then
    echo "ERROR: no simulator console log found. Run 'make ios-sim-run' first," >&2
    echo "       or pass a log path: $0 ios-log <path>" >&2
    exit 1
  fi
  echo "==> Parsing $input"
  parse_log "$input" "iOS app intervals" "$RUN_DIR/ios-log.json"
}

ios_trace() {
  local trace="$1"
  if [[ -z "$trace" || ! -e "$trace" ]]; then
    echo "usage: $0 ios-trace <path-to-profile.trace>" >&2
    echo "       record one with 'make ios-sim-run' (IOS_SIM_PROFILE=1)" >&2
    exit 1
  fi
  local xml="$RUN_DIR/signposts.xml"
  echo "==> Exporting signposts from $trace"
  xcrun xctrace export \
    --input "$trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
    > "$xml"
  if ! grep -q "<row>" "$xml"; then
    echo "ERROR: $trace contains no signpost rows." >&2
    echo "       A trace with no recorded process or a zero duration means the" >&2
    echo "       recording never attached to the app; re-record with:" >&2
    echo "         IOS_SIM_PROFILE=1 make ios-sim-run" >&2
    echo "       and drive the interaction while it records." >&2
    exit 1
  fi
  report "iOS signpost intervals" "$xml" "$RUN_DIR/ios-signposts.json"
}

android() {
  local adb="$ANDROID_SDK_ROOT/platform-tools/adb"
  local serial="${1:-}"
  if [[ ! -x "$adb" ]]; then
    echo "ERROR: adb not found at $adb (set ANDROID_SDK_ROOT)" >&2
    exit 1
  fi
  if [[ -z "$serial" ]]; then
    serial="$("$adb" devices | awk -F'\t' 'NR>1 && $2=="device" { print $1; exit }')"
  fi
  if [[ -z "$serial" ]]; then
    echo "ERROR: no connected emulator or device (adb devices)" >&2
    exit 1
  fi
  echo "==> Android device $serial"

  # Frame timings for whatever the app rendered since the last reset. This is
  # the only honest jank number: it covers every frame, not just the ones the
  # app instrumented.
  "$adb" -s "$serial" shell dumpsys gfxinfo "$ANDROID_PACKAGE" reset > "$RUN_DIR/android-framestats.txt"
  echo "==> Captured frame stats into $RUN_DIR/android-framestats.txt"
  python3 - "$RUN_DIR/android-framestats.txt" <<'PY'
import re, statistics, sys

text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
rows = []
in_section = False
for line in text.splitlines():
    if line.startswith("Janky frames"):
        in_section = True
        continue
    if not in_section:
        continue
    fields = line.split()
    if len(fields) < 3 or not fields[0].isdigit():
        continue
    try:
        rows.append(float(fields[1]))
    except ValueError:
        continue
if not rows:
    print("  no frame rows: the app rendered nothing since 'dumpsys gfxinfo reset'")
    raise SystemExit(0)
rows.sort()
def at(p):
    return rows[min(len(rows) - 1, int(len(rows) * p))]
print(f"  frames={len(rows)}  median={at(0.5):.2f}ms  p90={at(0.9):.2f}ms  p99={at(0.99):.2f}ms  worst={rows[-1]:.2f}ms")
print("  (compare median to the 16.67ms budget for 60fps)")
PY

  # Cold start: total time from `am start` to first frame.
  local start_log="$RUN_DIR/android-cold-start.txt"
  "$adb" -s "$serial" shell am force-stop "$ANDROID_PACKAGE"
  "$adb" -s "$serial" shell am start -W -n \
    "$ANDROID_PACKAGE/com.litter.android.MainActivity" > "$start_log" 2>&1 || true
  grep -E "TotalTime|WaitTime" "$start_log" || true

  # `PerfTrace` intervals and Rust request timings from the running app.
  "$adb" -s "$serial" logcat -d -s perf:L LitterRust:V > "$RUN_DIR/android-logcat.txt" 2>/dev/null || \
    "$adb" -s "$serial" logcat -d > "$RUN_DIR/android-logcat.txt"
  parse_log "$RUN_DIR/android-logcat.txt" "Android app intervals" "$RUN_DIR/android-log.json"
}

rust_log() {
  local input="$1"
  if [[ -z "$input" ]]; then
    input="$(/bin/ls -t "$ROOT"/artifacts/ios-sim-run/*/sim-console.log "$ROOT"/artifacts/android-*run/*/logcat.txt 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$input" || ! -f "$input" ]]; then
    echo "ERROR: no device log found. Run 'make ios-sim-run' or 'make android-emulator-run' first," >&2
    echo "       or pass a log path: $0 rust <path>" >&2
    exit 1
  fi
  echo "==> Parsing $input"
  parse_log "$input" "Rust request timings" "$RUN_DIR/rust.json"
}

case "${1:-all}" in
  ios-tests) ios_tests ;;
  ios-log)   ios_log "${2:-}" ;;
  ios-trace) ios_trace "${2:-}" ;;
  android)   android "${2:-}" ;;
  rust)      rust_log "${2:-}" ;;
  all)
    ios_log "" || true
    rust_log "" || true
    if [[ -x "${ANDROID_SDK_ROOT:-}/platform-tools/adb" ]]; then android "" || true; fi
    ;;
  *)
    echo "usage: $0 [ios-tests|ios-log [file]|ios-trace <trace>|android [serial]|rust [file]|all]" >&2
    exit 1
    ;;
esac
