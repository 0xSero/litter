#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_MODE="${ANDROID_RUN_MODE:-device}"
APK_PATH="${ANDROID_APK:-${ROOT_DIR}/apps/android/app/build/outputs/apk/debug/app-debug.apk}"
PACKAGE_NAME="${ANDROID_PACKAGE:-com.sigkitten.litter.android}"
ACTIVITY_NAME="${ANDROID_ACTIVITY:-com.litter.android.MainActivity}"
REINSTALL_ON_SIGNATURE_MISMATCH="${ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH:-1}"

case "${RUN_MODE}" in
  emulator)
    ARTIFACTS_ROOT="${ANDROID_RUN_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts/android-emulator-run}"
    ;;
  device)
    ARTIFACTS_ROOT="${ANDROID_RUN_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts/android-device-run}"
    ;;
  *)
    echo "ERROR: ANDROID_RUN_MODE must be 'device' or 'emulator' (got '${RUN_MODE}')" >&2
    exit 1
    ;;
esac

TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
RUN_DIR="${ARTIFACTS_ROOT}/${TIMESTAMP}"
LOGCAT_PATH="${RUN_DIR}/device-logcat.log"
INSTALL_LOG_PATH="${RUN_DIR}/install.log"
LAUNCH_LOG_PATH="${RUN_DIR}/launch.log"
METADATA_PATH="${RUN_DIR}/metadata.txt"

mkdir -p "${RUN_DIR}"

if [[ ! -f "${APK_PATH}" ]]; then
  echo "ERROR: APK not found: ${APK_PATH}" >&2
  exit 1
fi

select_device() {
  if [[ "${RUN_MODE}" == "emulator" ]]; then
    adb devices | awk -F'\t' 'NR>1 && $2=="device" && $1 ~ /^emulator-/ {print $1; exit}'
  else
    if [[ -n "${ANDROID_DEVICE_SERIAL:-}" ]]; then
      printf '%s\n' "${ANDROID_DEVICE_SERIAL}"
    else
      adb devices | awk -F'\t' '
        NR > 1 && $2 == "device" && $1 !~ /^emulator-/ {
          if ($1 !~ /^adb-.*_adb-tls-connect\._tcp$/) {
            selected = 1
            print $1
            exit
          }
          if (wireless == "") {
            wireless = $1
          }
        }
        END {
          if (!selected && wireless != "") {
            print wireless
          }
        }
      '
    fi
  fi
}

DEVICE="$(select_device)"
if [[ -z "${DEVICE}" ]]; then
  if [[ "${RUN_MODE}" == "emulator" ]]; then
    echo "ERROR: no emulator found (run one first)" >&2
  else
    echo "ERROR: no connected Android device found (set ANDROID_DEVICE_SERIAL=<serial> to override)" >&2
  fi
  exit 1
fi

cat > "${METADATA_PATH}" <<EOF
timestamp=${TIMESTAMP}
mode=${RUN_MODE}
device=${DEVICE}
apk=${APK_PATH}
package=${PACKAGE_NAME}
activity=${ACTIVITY_NAME}
EOF

echo "==> Using Android ${RUN_MODE} ${DEVICE}"
echo "==> Saving Android run artifacts to ${RUN_DIR}"

install_apk() {
  local output status
  set +e
  output="$(adb -s "${DEVICE}" install -r "${APK_PATH}" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "${output}" | tee "${INSTALL_LOG_PATH}"

  if [[ ${status} -eq 0 ]]; then
    return 0
  fi

  if grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' <<<"${output}"; then
    if [[ "${REINSTALL_ON_SIGNATURE_MISMATCH}" == "1" ]]; then
      echo "==> Installed app has a different signing key; uninstalling ${PACKAGE_NAME} and retrying..." | tee -a "${INSTALL_LOG_PATH}"
      adb -s "${DEVICE}" uninstall "${PACKAGE_NAME}" | tee -a "${INSTALL_LOG_PATH}"
      adb -s "${DEVICE}" install -r "${APK_PATH}" 2>&1 | tee -a "${INSTALL_LOG_PATH}"
      return 0
    fi
    echo "ERROR: installed app signature does not match this APK. Re-run with ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH=1 to uninstall the existing app and install this build." >&2
    return "${status}"
  fi

  if grep -q 'INSTALL_FAILED_VERSION_DOWNGRADE' <<<"${output}"; then
    echo "==> Installed app has a higher versionCode; uninstalling ${PACKAGE_NAME} and retrying..." | tee -a "${INSTALL_LOG_PATH}"
    adb -s "${DEVICE}" uninstall "${PACKAGE_NAME}" | tee -a "${INSTALL_LOG_PATH}"
    adb -s "${DEVICE}" install -r "${APK_PATH}" 2>&1 | tee -a "${INSTALL_LOG_PATH}"
    return 0
  fi

  return "${status}"
}

install_apk

echo "==> Launching ${PACKAGE_NAME}/${ACTIVITY_NAME}..."
adb -s "${DEVICE}" shell am force-stop "${PACKAGE_NAME}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" shell am start -W -n "${PACKAGE_NAME}/${ACTIVITY_NAME}" 2>&1 | tee "${LAUNCH_LOG_PATH}" >/dev/null

PID=""
for _ in $(seq 1 50); do
  PID="$(adb -s "${DEVICE}" shell pidof -s "${PACKAGE_NAME}" 2>/dev/null | tr -d '\r')"
  if [[ -n "${PID}" ]]; then
    break
  fi
  sleep 0.2
done

if [[ -z "${PID}" ]]; then
  echo "ERROR: app launched but no PID found for ${PACKAGE_NAME}" >&2
  exit 1
fi

{
  echo "pid=${PID}"
  echo "logcat=${LOGCAT_PATH}"
} >> "${METADATA_PATH}"

echo "==> Streaming logcat for ${PACKAGE_NAME} (pid ${PID})..."
echo "==> Logcat artifact: ${LOGCAT_PATH}"
adb -s "${DEVICE}" logcat --pid="${PID}" -v time | tee "${LOGCAT_PATH}"
