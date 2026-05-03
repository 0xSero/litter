#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
APP_PATH="$(/bin/ls -dt "${DERIVED_DATA_ROOT}"/Litter-*/Build/Products/Debug-iphoneos/Litter.app 2>/dev/null | head -1 || true)"
BUNDLE_ID="com.sigkitten.litter"
APP_EXECUTABLE_NAME="$(basename "${APP_PATH}" .app)"

PROFILE_ENABLED="${IOS_DEVICE_PROFILE:-1}"
PROFILE_TEMPLATE="${IOS_DEVICE_PROFILE_TEMPLATE:-Time Profiler}"
PROFILE_TIME_LIMIT="${IOS_DEVICE_PROFILE_TIME_LIMIT:-}"
# When 1, xctrace launches the app itself (`--launch -- <app>`) instead of
# attaching post-launch. Required for SwiftUI signposts (View Body
# Updates, Representable Updates) — those streams are only registered if
# the process comes up under Instruments. Trade-off: devicectl's console
# streaming is skipped in this mode since xctrace owns the process.
PROFILE_LAUNCH_MODE="${IOS_DEVICE_PROFILE_LAUNCH:-0}"
# When 1 (with launch-mode also on), kick xctrace off into the background
# and exit the script immediately. You get back your shell; the trace
# keeps recording. Stop it later with `kill -INT <pid>` — the PID is
# printed to stdout and saved to `<RUN_DIR>/profile.pid`.
PROFILE_DETACH="${IOS_DEVICE_PROFILE_DETACH:-0}"
ARTIFACTS_ROOT="${IOS_RUN_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts/ios-device-run}"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
RUN_DIR="${ARTIFACTS_ROOT}/${TIMESTAMP}"
CONSOLE_LOG_PATH="${RUN_DIR}/device-console.log"
LAUNCH_JSON_PATH="${RUN_DIR}/launch.json"
TRACE_PATH="${RUN_DIR}/profile.trace"
PROFILE_LOG_PATH="${RUN_DIR}/profile.log"
DEVICECTL_PID_FILE="${RUN_DIR}/devicectl.pid"
CONSOLE_PID=""
PROFILE_PID=""
PROFILE_ATTACH_RETRY_LIMIT="${IOS_DEVICE_PROFILE_ATTACH_RETRY_LIMIT:-15}"
PROFILE_ATTACH_RETRY_DELAY="${IOS_DEVICE_PROFILE_ATTACH_RETRY_DELAY:-0.5}"
IOS_DEVICE_OVERRIDE="${IOS_DEVICE_ID:-${IOS_DEVICE_UDID:-}}"
TAILSCALE_DEVICE="${TAILSCALE_DEVICE:-}"
TUNNEL_PID=""
TAILSCALE_BIN="${TAILSCALE_BIN:-}"

mkdir -p "${RUN_DIR}"

if [[ -z "${APP_PATH}" ]]; then
  echo "ERROR: Litter.app not found in DerivedData" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Device discovery — try local first, fall back to Tailscale tunnel
# ---------------------------------------------------------------------------
discover_devices() {
  local out="$1"
  xcrun devicectl list devices --json-output "${out}" >/dev/null 2>&1 || true
}

select_device() {
  local json_path="$1"
  local override="$2"
  python3 - "${json_path}" "${override}" <<'PY'
import json, os, sys

path = sys.argv[1]
override = sys.argv[2].strip()

if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as fh:
        payload = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

devices = payload.get("result", {}).get("devices", [])

def summarize(d):
    identifier = d.get("identifier", "")
    hw = d.get("hardwareProperties", {})
    props = d.get("deviceProperties", {})
    conn = d.get("connectionProperties", {})
    udid = hw.get("udid", "")
    ecid = str(hw.get("ecid", "") or "")
    name = props.get("name", "")
    tunnel_state = conn.get("tunnelState", "")
    pairing_state = conn.get("pairingState", "")
    ddi = props.get("ddiServicesAvailable", False)
    xctrace_id = udid or name or identifier
    rank = 0
    if tunnel_state == "connected":
        rank = 3
    elif tunnel_state and tunnel_state != "unavailable":
        rank = 2
    elif ddi:
        rank = 1
    return {
        "identifier": identifier, "udid": udid, "ecid": ecid,
        "name": name, "tunnel_state": tunnel_state,
        "pairing_state": pairing_state, "ddi_available": ddi,
        "xctrace_id": xctrace_id, "state_rank": rank,
    }

sums = [summarize(d) for d in devices]

selected = None
if override:
    for c in sums:
        if override in {c["identifier"], c["udid"], c["ecid"],
                        f'ecid_{c["ecid"]}' if c["ecid"] else ""}:
            selected = c
            break

if selected is None:
    paired = [c for c in sums if c["pairing_state"] == "paired"]
    ranked = sorted(paired, key=lambda c: (c["state_rank"], bool(c["udid"]), c["name"]), reverse=True)
    if ranked:
        selected = ranked[0]

if selected is None:
    sys.exit(0)

print("\t".join([
    selected["identifier"], selected["xctrace_id"], selected["name"],
    selected["tunnel_state"], selected["pairing_state"],
    "1" if selected["ddi_available"] else "0", str(selected["state_rank"]),
]))
PY
}

device_is_reachable() {
  local sel="$1"
  [[ -n "${sel}" ]] || return 1
  local rank
  rank="$(echo "${sel}" | cut -f7)"
  [[ "${rank}" -gt 0 ]]
}

resolve_tailscale_ios_peers() {
  # Prints "hostname<TAB>ip" lines for iOS peers on the tailnet.
  # If TAILSCALE_DEVICE is set, only return that one.
  local filter="$1"
  local json_output
  json_output="$("${TAILSCALE_BIN}" status --json 2>/dev/null || true)"
  if [[ -n "${json_output}" ]]; then
    TAILSCALE_STATUS_JSON="${json_output}" python3 - "${filter}" <<'PY'
import json, os, sys
name_filter = sys.argv[1].strip().lower()
raw = os.environ.get("TAILSCALE_STATUS_JSON", "")
if not raw.strip():
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
peers = []
for peer in (data.get("Peer") or {}).values():
    hostname = (peer.get("HostName") or "").strip()
    os_name = (peer.get("OS") or "").lower()
    ips = peer.get("TailscaleIPs") or []
    if not ips:
        continue
    # prefer IPv4
    ip = next((i for i in ips if "." in i), ips[0])
    if name_filter:
        if hostname.lower() == name_filter:
            print(f"{hostname}\t{ip}")
            break
    elif os_name == "ios":
        peers.append((hostname, ip))
for hostname, ip in peers:
    print(f"{hostname}\t{ip}")
PY
    return 0
  fi

  TAILSCALE_STATUS_TEXT="$("${TAILSCALE_BIN}" status 2>/dev/null || true)" python3 - "${filter}" <<'PY'
import os, sys

name_filter = sys.argv[1].strip().lower()
peers = []

for raw_line in os.environ.get("TAILSCALE_STATUS_TEXT", "").splitlines():
    line = raw_line.rstrip("\n")
    if not line.strip():
        continue
    parts = line.split()
    if len(parts) < 4:
        continue
    ip, hostname, _, os_name = parts[:4]
    if "." not in ip:
        continue
    if os_name.lower() != "ios":
        continue
    if name_filter:
        if hostname.lower() == name_filter:
            print(f"{hostname}\t{ip}")
            break
    else:
        peers.append((hostname, ip))

for hostname, ip in peers:
    print(f"{hostname}\t{ip}")
PY
}

start_tailscale_tunnel() {
  local log="${RUN_DIR}/tunnel.log"
  echo "==> Starting pymobiledevice3 WiFi tunnel for ${DEVICE_NAME} (${DEVICE_UDID})..."
  sudo -n /usr/local/bin/litter-ios-remote start-tunnel --connection-type wifi --udid "${DEVICE_UDID}" \
    > "${log}" 2>&1 &
  TUNNEL_PID=$!
  # wait for the tunnel to come up (devicectl should see the device)
  local attempt=0
  local max_attempts=30
  while (( attempt < max_attempts )); do
    sleep 1
    ((attempt++))
    discover_devices "${DEVICE_LIST_JSON}"
    local sel
    sel="$(select_device "${DEVICE_LIST_JSON}" "${IOS_DEVICE_OVERRIDE}")" || true
    if device_is_reachable "${sel}"; then
      echo "==> Device reachable via Tailscale tunnel (attempt ${attempt}/${max_attempts})"
      return 0
    fi
  done
  echo "ERROR: device not reachable after ${max_attempts}s via Tailscale tunnel" >&2
  echo "       tunnel log: ${log}" >&2
  kill "${TUNNEL_PID}" 2>/dev/null || true
  TUNNEL_PID=""
  return 1
}

DEVICE_LIST_JSON="${RUN_DIR}/devices.json"
discover_devices "${DEVICE_LIST_JSON}"

DEVICE_SELECTION="$(select_device "${DEVICE_LIST_JSON}" "${IOS_DEVICE_OVERRIDE}")" || true
DEVICE_UDID="$(python3 - "${DEVICE_LIST_JSON}" "${IOS_DEVICE_OVERRIDE}" <<'PY'
import json, os, sys

path = sys.argv[1]
override = sys.argv[2].strip()

if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as fh:
        payload = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

for device in payload.get("result", {}).get("devices", []):
    hw = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    udid = hw.get("udid", "") or ""
    ecid = str(hw.get("ecid", "") or "")
    identifier = device.get("identifier", "") or ""
    name = props.get("name", "") or ""
    if override and override not in {identifier, udid, ecid, f"ecid_{ecid}" if ecid else ""}:
        continue
    print(udid)
    break
PY
)" || true
DEVICE_NAME="$(python3 - "${DEVICE_LIST_JSON}" "${IOS_DEVICE_OVERRIDE}" <<'PY'
import json, os, sys

path = sys.argv[1]
override = sys.argv[2].strip()

if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as fh:
        payload = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

for device in payload.get("result", {}).get("devices", []):
    hw = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    udid = hw.get("udid", "") or ""
    ecid = str(hw.get("ecid", "") or "")
    identifier = device.get("identifier", "") or ""
    name = props.get("name", "") or ""
    if override and override not in {identifier, udid, ecid, f"ecid_{ecid}" if ecid else ""}:
        continue
    print(name)
    break
PY
)" || true

if [[ -z "${TAILSCALE_BIN}" ]]; then
  if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_BIN="$(command -v tailscale)"
  elif [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
    TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  fi
fi

# If device not reachable, try Tailscale fallback
if ! device_is_reachable "${DEVICE_SELECTION}"; then
  if [[ -z "${TAILSCALE_BIN}" ]]; then
    echo "WARN: device not found locally and tailscale is not installed — skipping remote fallback" >&2
  elif ! command -v pymobiledevice3 >/dev/null 2>&1; then
    echo "WARN: device not found locally but pymobiledevice3 is not installed" >&2
    echo "      install it with: pipx install pymobiledevice3" >&2
    echo "      or:              uv tool install pymobiledevice3" >&2
  elif [[ -z "${DEVICE_UDID}" ]]; then
    echo "WARN: device not found locally and its UDID could not be resolved for remote fallback" >&2
  elif ! sudo -n true >/dev/null 2>&1; then
    echo "WARN: device not found locally and remote tunneling requires passworded sudo in this shell" >&2
    echo "      run again from an interactive terminal where sudo can prompt" >&2
  fi
  if [[ -n "${TAILSCALE_BIN}" ]] && command -v pymobiledevice3 >/dev/null 2>&1 && [[ -n "${DEVICE_UDID}" ]] && sudo -n true >/dev/null 2>&1; then
    TS_PEERS="$(resolve_tailscale_ios_peers "${TAILSCALE_DEVICE}")" || true
    if [[ -z "${TS_PEERS}" ]]; then
      if [[ -n "${TAILSCALE_DEVICE}" ]]; then
        echo "WARN: '${TAILSCALE_DEVICE}' not found on your tailnet" >&2
      else
        echo "WARN: no iOS peers found on your tailnet" >&2
        echo "      set TAILSCALE_DEVICE to your phone's Tailscale hostname" >&2
      fi
    else
      while IFS=$'\t' read -r ts_name ts_ip; do
        echo "==> Device not found locally, trying Tailscale (${ts_name} @ ${ts_ip})..."
        if start_tailscale_tunnel; then
          DEVICE_SELECTION="$(select_device "${DEVICE_LIST_JSON}" "${IOS_DEVICE_OVERRIDE}")" || true
          break
        fi
      done <<< "${TS_PEERS}"
    fi
  fi
fi

# Legacy inline selection removed — now uses select_device() above
if [[ -z "${DEVICE_SELECTION}" ]]; then
  echo "ERROR: no paired iOS device found via devicectl" >&2
  exit 1
fi

IFS=$'\t' read -r DEVICE_ID XCTRACE_DEVICE_ID DEVICE_NAME DEVICE_TUNNEL_STATE DEVICE_PAIRING_STATE DEVICE_DDI_AVAILABLE DEVICE_STATE_RANK <<<"${DEVICE_SELECTION}"

if [[ -z "${DEVICE_ID}" ]]; then
  echo "ERROR: failed to resolve a usable device identifier" >&2
  exit 1
fi

if [[ "${DEVICE_STATE_RANK}" == "0" ]]; then
  echo "ERROR: selected device is paired but currently unreachable:" >&2
  echo "  name=${DEVICE_NAME}" >&2
  echo "  identifier=${DEVICE_ID}" >&2
  echo "  xctrace_device=${XCTRACE_DEVICE_ID}" >&2
  echo "  tunnel_state=${DEVICE_TUNNEL_STATE:-unknown}" >&2
  echo "  ddi_services_available=${DEVICE_DDI_AVAILABLE}" >&2
  echo "Reconnect/unlock the device or pass IOS_DEVICE_ID/IOS_DEVICE_UDID to override." >&2
  exit 1
fi

lookup_running_pid() {
  local output_json=$1
  xcrun devicectl device info processes --device "${DEVICE_ID}" --json-output "${output_json}" >/dev/null 2>&1 || return 0
  python3 - "${output_json}" "${APP_EXECUTABLE_NAME}" <<'PY'
import json
import os
import sys
from urllib.parse import urlparse

path = sys.argv[1]
expected_name = sys.argv[2]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

matches = []
for process in payload.get("result", {}).get("runningProcesses", []):
    executable = process.get("executable", "")
    parsed = urlparse(executable)
    executable_path = parsed.path or executable
    if executable_path.endswith(f"/{expected_name}.app/{expected_name}"):
        pid = process.get("processIdentifier")
        if pid:
            matches.append(pid)

if matches:
    print(max(matches))
PY
}

start_profiler_with_retry() {
  local pid="$1"
  shift
  local -a record_args=("$@")
  local attempt=1
  local attach_log=""

  : > "${PROFILE_LOG_PATH}"

  while (( attempt <= PROFILE_ATTACH_RETRY_LIMIT )); do
    {
      echo "==> profiler attach attempt ${attempt}/${PROFILE_ATTACH_RETRY_LIMIT} for pid ${pid}"
      printf '==> command:'
      printf ' %q' "${record_args[@]}"
      printf '\n'
    } >> "${PROFILE_LOG_PATH}"

    "${record_args[@]}" >>"${PROFILE_LOG_PATH}" 2>&1 &
    local candidate_pid=$!
    sleep 1

    if kill -0 "${candidate_pid}" 2>/dev/null; then
      PROFILE_PID="${candidate_pid}"
      return 0
    fi

    wait "${candidate_pid}" 2>/dev/null || true
    attach_log="$(tail -n 20 "${PROFILE_LOG_PATH}" 2>/dev/null || true)"
    if [[ "${attach_log}" != *"Cannot find process for provided pid"* ]]; then
      return 1
    fi

    sleep "${PROFILE_ATTACH_RETRY_DELAY}"
    pid="$(lookup_running_pid "${RUN_DIR}/processes.json")"
    if [[ -z "${pid}" ]]; then
      ((attempt++))
      continue
    fi

    record_args=()
    if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
      record_args=(
        xcrun xctrace record
        --template "${PROFILE_TEMPLATE}"
        --device "${XCTRACE_DEVICE_ID}"
        --attach "${pid}"
        --output "${TRACE_PATH}"
        --no-prompt
        --time-limit "${PROFILE_TIME_LIMIT}"
      )
    else
      record_args=(
        xcrun xctrace record
        --template "${PROFILE_TEMPLATE}"
        --device "${XCTRACE_DEVICE_ID}"
        --attach "${pid}"
        --output "${TRACE_PATH}"
        --no-prompt
      )
    fi
    ((attempt++))
  done

  return 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "${PROFILE_PID}" ]]; then
    # Send SIGINT to xctrace so it flushes and finalizes the .trace file,
    # but DO NOT wait for it. Finalize can take several seconds for a
    # long capture, and we want the user's terminal back immediately
    # so they can re-run. Disown it from the shell's job table so it
    # survives our exit without a SIGHUP.
    echo
    echo "==> Stopping profiler; trace will finalize in background (pid ${PROFILE_PID})."
    kill -INT "${PROFILE_PID}" 2>/dev/null || true
    disown "${PROFILE_PID}" 2>/dev/null || true
  fi

  # devicectl --console does not exit on SIGINT when its stdout is piped,
  # so the tee/perl filters alone can't unblock the wait. Kill devicectl
  # explicitly; the pipe then closes and the filters drain.
  if [[ -f "${DEVICECTL_PID_FILE}" ]]; then
    devicectl_pid="$(cat "${DEVICECTL_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${devicectl_pid}" ]]; then
      kill -TERM "${devicectl_pid}" 2>/dev/null || true
    fi
  fi

  if [[ -n "${CONSOLE_PID}" ]]; then
    kill "${CONSOLE_PID}" 2>/dev/null || true
    # Console pipe is quick to close — safe to wait briefly.
    wait "${CONSOLE_PID}" 2>/dev/null || true
  fi

  if [[ -n "${TUNNEL_PID}" ]]; then
    echo "==> Stopping Tailscale tunnel..."
    sudo -n kill -TERM "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi

  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# Forward LITTER_* env vars from the calling shell into the on-device
# process so flags like LITTER_FORCE_BETA_SUNSET=1 work the same as the
# SIMCTL_CHILD_* path on simulator. devicectl picks up any env var
# prefixed with DEVICECTL_CHILD_ and strips the prefix on launch.
while IFS= read -r litter_env_line; do
  [[ "${litter_env_line}" == LITTER_*=* ]] || continue
  export "DEVICECTL_CHILD_${litter_env_line%%=*}=${litter_env_line#*=}"
done < <(env)
unset litter_env_line

echo "==> Installing on device ${DEVICE_ID}..."
xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"

echo "==> Artifacts:"
echo "    console log: ${CONSOLE_LOG_PATH}"
if [[ "${PROFILE_ENABLED}" == "1" ]]; then
  echo "    profile trace: ${TRACE_PATH}"
  echo "    profile log: ${PROFILE_LOG_PATH}"
fi

if [[ "${PROFILE_ENABLED}" == "1" && "${PROFILE_LAUNCH_MODE}" == "1" ]]; then
  # Launch-mode: xctrace brings the app up, which enables SwiftUI
  # signposts. devicectl console streaming is incompatible with this
  # (xctrace owns the process), so we skip it.
  echo "==> Launching app under xctrace (${PROFILE_TEMPLATE})..."
  echo "    Note: device console log is NOT captured in this mode."
  echo "    Use 'xcrun devicectl device process monitor --device ${DEVICE_ID}' in"
  echo "    another terminal if you need live logs alongside the trace."
  RECORD_ARGS=(
    xcrun xctrace record
    --template "${PROFILE_TEMPLATE}"
    --device "${XCTRACE_DEVICE_ID}"
    --output "${TRACE_PATH}"
    --no-prompt
  )
  if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
    RECORD_ARGS+=(--time-limit "${PROFILE_TIME_LIMIT}")
  fi
  RECORD_ARGS+=(--launch -- "${APP_PATH}")

  if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
    echo "==> xctrace will stop after ${PROFILE_TIME_LIMIT} and finalize ${TRACE_PATH}."
  else
    echo "==> xctrace will record until you Ctrl+C and then finalize ${TRACE_PATH}."
  fi
  # Background xctrace so the `cleanup` trap can forward SIGINT to it on
  # Ctrl+C — the trap reads PROFILE_PID and signals that specific pid so
  # the trace finalizes cleanly instead of being truncated.
  "${RECORD_ARGS[@]}" >"${PROFILE_LOG_PATH}" 2>&1 &
  BG_XCTRACE_PID=$!

  if [[ "${PROFILE_DETACH}" == "1" ]]; then
    # Detach: disown so the process survives script exit, persist the
    # pid for later, and drop the trap's reference so `cleanup` doesn't
    # signal xctrace on our exit path.
    echo "${BG_XCTRACE_PID}" > "${RUN_DIR}/profile.pid"
    disown "${BG_XCTRACE_PID}" 2>/dev/null || true
    PROFILE_PID=""
    echo ""
    echo "==> xctrace running in background (pid ${BG_XCTRACE_PID})."
    echo "    Stop gracefully (trace finalizes):  kill -INT ${BG_XCTRACE_PID}"
    echo "    Output:                             ${TRACE_PATH}"
    echo "    Log:                                ${PROFILE_LOG_PATH}"
    # Still stop the console pipe and tailscale tunnel before exiting.
    if [[ -n "${CONSOLE_PID}" ]]; then
      kill "${CONSOLE_PID}" 2>/dev/null || true
      wait "${CONSOLE_PID}" 2>/dev/null || true
      CONSOLE_PID=""
    fi
    # Clear trap so the EXIT path doesn't try to kill the disowned pid.
    trap - EXIT INT TERM
    exit 0
  else
    PROFILE_PID="${BG_XCTRACE_PID}"
    wait "${PROFILE_PID}" 2>/dev/null || true
    PROFILE_PID=""
  fi
else
  echo "==> Launching app and attaching console (Ctrl+C stops console streaming)..."
  # Spawn devicectl inside a subshell so its PID can be captured before the
  # pipeline consumes $!. Needed because devicectl --console ignores SIGINT
  # when its stdout is piped; the cleanup trap kills it by PID instead.
  { xcrun devicectl device process launch --device "${DEVICE_ID}" --terminate-existing \
      --console --json-output "${LAUNCH_JSON_PATH}" "${BUNDLE_ID}" 2>&1 &
    echo $! > "${DEVICECTL_PID_FILE}"
    wait
  } | tee >(
      perl -MPOSIX=strftime -ne 'BEGIN { $| = 1 } print strftime("[%Y-%m-%d %H:%M:%S] ", localtime), $_' > "${CONSOLE_LOG_PATH}"
    ) | perl -MPOSIX=strftime -ne 'BEGIN { $| = 1 } print strftime("[%Y-%m-%d %H:%M:%S] ", localtime), $_' &
  CONSOLE_PID=$!

  if [[ "${PROFILE_ENABLED}" == "1" ]]; then
    PID=""
    for _ in $(seq 1 50); do
      PID="$(lookup_running_pid "${RUN_DIR}/processes.json")"
      if [[ -n "${PID}" ]]; then
        sleep 0.5
        latest_pid="$(lookup_running_pid "${RUN_DIR}/processes.json")"
        if [[ -n "${latest_pid}" ]]; then
          PID="${latest_pid}"
        fi
        break
      fi
      sleep 0.2
    done

    if [[ -n "${PID}" ]]; then
      RECORD_ARGS=(
        xcrun xctrace record
        --template "${PROFILE_TEMPLATE}"
        --device "${XCTRACE_DEVICE_ID}"
        --attach "${PID}"
        --output "${TRACE_PATH}"
        --no-prompt
      )
      if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
        RECORD_ARGS+=(--time-limit "${PROFILE_TIME_LIMIT}")
        echo "==> Starting ${PROFILE_TEMPLATE} for pid ${PID} (${PROFILE_TIME_LIMIT})..."
      else
        echo "==> Starting ${PROFILE_TEMPLATE} for pid ${PID} for the full run..."
      fi
      if start_profiler_with_retry "${PID}" "${RECORD_ARGS[@]}"; then
        if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
          echo "==> Profiler will stop automatically when the time limit is reached."
        else
          echo "==> Profiler will stop when this run stops and then finalize ${TRACE_PATH}."
        fi
      else
        PROFILE_PID=""
        echo "WARN: failed to attach profiler after ${PROFILE_ATTACH_RETRY_LIMIT} attempts; see ${PROFILE_LOG_PATH}" >&2
      fi
    else
      echo "WARN: could not resolve ${APP_EXECUTABLE_NAME} pid on device; skipping profiler capture" >&2
    fi
  else
    echo "==> Profiler disabled (IOS_DEVICE_PROFILE=${PROFILE_ENABLED})."
  fi

  wait "${CONSOLE_PID}"
fi
