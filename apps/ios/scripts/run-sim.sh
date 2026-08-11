#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
APP_PATH="$(/bin/ls -dt "${DERIVED_DATA_ROOT}"/Litter-*/Build/Products/Debug-iphonesimulator/Litter.app 2>/dev/null | head -1 || true)"
BUNDLE_ID="com.sigkitten.litter"

PROFILE_ENABLED="${IOS_SIM_PROFILE:-0}"
PROFILE_TIME_LIMIT="${IOS_SIM_PROFILE_TIME_LIMIT:-}"
ARTIFACTS_ROOT="${IOS_SIM_RUN_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts/ios-sim-run}"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
RUN_DIR="${ARTIFACTS_ROOT}/${TIMESTAMP}"
CONSOLE_LOG_PATH="${RUN_DIR}/sim-console.log"
TRACE_PATH="${RUN_DIR}/profile.trace"
PROFILE_LOG_PATH="${RUN_DIR}/profile.log"
CONSOLE_PID=""
PROFILE_PID=""

mkdir -p "${RUN_DIR}"

if [[ -z "${APP_PATH}" ]]; then
  echo "ERROR: Litter.app not found in DerivedData (Debug-iphonesimulator)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Find a booted simulator
# ---------------------------------------------------------------------------
SIM_UDID="$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('state') == 'Booted':
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || true)"

if [[ -z "${SIM_UDID}" ]]; then
  echo "ERROR: no booted simulator found. Boot one first (e.g. xcrun simctl boot \"iPhone 17 Pro\")" >&2
  exit 1
fi

SIM_NAME="$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('udid') == '${SIM_UDID}':
            print(d.get('name', 'Unknown'))
            sys.exit(0)
" 2>/dev/null || true)"

echo "==> Using simulator: ${SIM_NAME} (${SIM_UDID})"

# ---------------------------------------------------------------------------
# Cleanup handler
# ---------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "${PROFILE_PID}" ]]; then
    echo
    echo "==> Stopping profiler and finalizing trace..."
    kill -INT "${PROFILE_PID}" 2>/dev/null || true
    wait "${PROFILE_PID}" 2>/dev/null || true
  fi

  if [[ -n "${CONSOLE_PID}" ]]; then
    kill "${CONSOLE_PID}" 2>/dev/null || true
    wait "${CONSOLE_PID}" 2>/dev/null || true
  fi

  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
echo "==> Installing on simulator ${SIM_UDID}..."
xcrun simctl install "${SIM_UDID}" "${APP_PATH}"

echo "==> Artifacts:"
echo "    console log: ${CONSOLE_LOG_PATH}"
if [[ "${PROFILE_ENABLED}" == "1" ]]; then
  echo "    profile trace: ${TRACE_PATH}"
  echo "    profile log: ${PROFILE_LOG_PATH}"
fi

# ---------------------------------------------------------------------------
# Terminate any existing instance so --console-pty gets a fresh launch
# ---------------------------------------------------------------------------
xcrun simctl terminate "${SIM_UDID}" "${BUNDLE_ID}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Launch with console streaming
# ---------------------------------------------------------------------------
echo "==> Launching app and attaching console (Ctrl+C stops)..."
xcrun simctl launch --console-pty "${SIM_UDID}" "${BUNDLE_ID}" \
  2>&1 | tee >(
    perl -MPOSIX=strftime -ne 'BEGIN { $| = 1 } print strftime("[%Y-%m-%d %H:%M:%S] ", localtime), $_' > "${CONSOLE_LOG_PATH}"
  ) | perl -MPOSIX=strftime -ne 'BEGIN { $| = 1 } print strftime("[%Y-%m-%d %H:%M:%S] ", localtime), $_' &
CONSOLE_PID=$!

# ---------------------------------------------------------------------------
# Profiler
# ---------------------------------------------------------------------------
if [[ "${PROFILE_ENABLED}" == "1" ]]; then
  # Wait for the app process to appear
  APP_PID=""
  for _ in $(seq 1 20); do
    sleep 0.5
    APP_PID="$(pgrep -f 'Litter\.app/Litter$' 2>/dev/null | while read -r pid; do
      if ! ps -p "$pid" -o args= 2>/dev/null | grep -q PlugIns; then
        echo "$pid"
        break
      fi
    done)"
    if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
      break
    fi
    APP_PID=""
  done

  if [[ -n "${APP_PID}" ]]; then
    # Simulator processes can't use ktrace-based templates (Time Profiler,
    # Allocations, etc.) but "CPU Profiler" uses kperf sampling and works.
    # Clear stale kernel trace buffers that block new recordings.
    sudo ktrace reset 2>/dev/null || true
    SIM_TEMPLATE="CPU Profiler"
    RECORD_ARGS=(
      xcrun xctrace record
      --template "${SIM_TEMPLATE}"
      --device "${SIM_UDID}"
      --attach "${APP_PID}"
      --output "${TRACE_PATH}"
      --no-prompt
    )
    if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
      RECORD_ARGS+=(--time-limit "${PROFILE_TIME_LIMIT}")
      echo "==> Starting ${SIM_TEMPLATE} for pid ${APP_PID} (${PROFILE_TIME_LIMIT})..."
    else
      echo "==> Starting ${SIM_TEMPLATE} for pid ${APP_PID} for the full run..."
    fi

    : > "${PROFILE_LOG_PATH}"
    "${RECORD_ARGS[@]}" >>"${PROFILE_LOG_PATH}" 2>&1 &
    PROFILE_PID=$!

    sleep 2
    if kill -0 "${PROFILE_PID}" 2>/dev/null; then
      if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
        echo "==> Profiler will stop automatically when the time limit is reached."
      else
        echo "==> Profiler will stop when this run stops and then finalize ${TRACE_PATH}."
      fi
    else
      wait "${PROFILE_PID}" 2>/dev/null || true
      PROFILE_PID=""
      echo "WARN: failed to attach profiler; see ${PROFILE_LOG_PATH}" >&2
    fi
  else
    echo "WARN: could not resolve Litter pid on simulator; skipping profiler" >&2
  fi
else
  echo "==> Profiler disabled (IOS_SIM_PROFILE=${PROFILE_ENABLED})."
fi

wait "${CONSOLE_PID}"
