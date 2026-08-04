#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
IOS_DIR="${ROOT_DIR}/apps/ios"
PROJECT_PATH="${IOS_DIR}/Litter.xcodeproj"
SCHEME="${IOS_SCHEME:-Litter}"
CONFIGURATION="${XCODE_CONFIG:-Debug}"
ONLY_ACTIVE_ARCH="${IOS_DEVICE_ONLY_ACTIVE_ARCH:-0}"
DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
SIGNING_STATE_DIR="${HOME}/Library/Application Support/LitterBuild"
LOCAL_SIGNING_MARKER="${SIGNING_STATE_DIR}/use-local-device-signing"

BUILD_LOG="$(mktemp /tmp/litter-device-build.XXXXXX)"
PROFILE_LIST="$(mktemp /tmp/litter-device-profiles.XXXXXX)"
PROFILE_INFO="$(mktemp /tmp/litter-device-profile-info.XXXXXX)"
ENTITLEMENTS_PLIST="$(mktemp /tmp/litter-device-entitlements.XXXXXX)"
cleanup() {
  rm -f "${BUILD_LOG}" "${PROFILE_LIST}" "${PROFILE_INFO}" "${ENTITLEMENTS_PLIST}"
}
trap cleanup EXIT

build_args=(
  xcodebuild
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "generic/platform=iOS"
  -allowProvisioningUpdates
  COMPILER_INDEX_STORE_ENABLE=NO
)
if [[ "${ONLY_ACTIVE_ARCH}" == "1" ]]; then
  build_args+=(ONLY_ACTIVE_ARCH=YES)
fi
build_args+=(build)

USE_LOCAL_SIGNING=0
if [[ "${IOS_FORCE_LOCAL_SIGNING:-0}" == "1" ]]; then
  USE_LOCAL_SIGNING=1
elif [[ -f "${LOCAL_SIGNING_MARKER}" && "${IOS_FORCE_CANONICAL_SIGNING:-0}" != "1" ]]; then
  USE_LOCAL_SIGNING=1
fi

if [[ "${USE_LOCAL_SIGNING}" == "0" ]]; then
  set +e
  "${build_args[@]}" 2>&1 | tee "${BUILD_LOG}"
  build_status=${PIPESTATUS[0]}
  set -e
  if [[ "${build_status}" == "0" ]]; then
    rm -f "${LOCAL_SIGNING_MARKER}"
    exit 0
  fi

  if ! grep -Eq \
    'No Account for Team|No profiles for|requires a provisioning profile|requires a development team' \
    "${BUILD_LOG}"; then
    exit "${build_status}"
  fi
else
  echo "==> Reusing remembered local device signing configuration."
fi

echo "==> Canonical signing is unavailable; trying a local development profile..."

if [[ -n "${IOS_LOCAL_PROVISIONING_PROFILE:-}" ]]; then
  if [[ ! -f "${IOS_LOCAL_PROVISIONING_PROFILE}" ]]; then
    echo "ERROR: IOS_LOCAL_PROVISIONING_PROFILE does not exist: ${IOS_LOCAL_PROVISIONING_PROFILE}" >&2
    exit 1
  fi
  printf '%s\n' "${IOS_LOCAL_PROVISIONING_PROFILE}" > "${PROFILE_LIST}"
else
  if [[ -d "${HOME}/Library/MobileDevice/Provisioning Profiles" ]]; then
    find "${HOME}/Library/MobileDevice/Provisioning Profiles" \
      -maxdepth 1 -type f -name '*.mobileprovision' -print >> "${PROFILE_LIST}"
  fi
  find "${DERIVED_DATA_ROOT}" -path '*/Litter.app/embedded.mobileprovision' \
    -type f -print >> "${PROFILE_LIST}" 2>/dev/null || true
fi

python3 - "${PROFILE_LIST}" "${PROFILE_INFO}" <<'PY'
import datetime
import hashlib
import os
import plistlib
import subprocess
import sys

profile_list, output_path = sys.argv[1:3]
identity_output = subprocess.run(
    ["security", "find-identity", "-v", "-p", "codesigning"],
    check=False,
    capture_output=True,
    text=True,
).stdout.upper()

candidates = []
seen = set()
with open(profile_list, encoding="utf-8") as fh:
    paths = [line.strip() for line in fh if line.strip()]

for path in paths:
    try:
        real_path = os.path.realpath(path)
        if real_path in seen:
            continue
        seen.add(real_path)
        decoded = subprocess.run(
            ["security", "cms", "-D", "-i", real_path],
            check=True,
            capture_output=True,
        ).stdout
        profile = plistlib.loads(decoded)
        entitlements = profile.get("Entitlements", {})
        app_identifier = entitlements.get("application-identifier", "")
        if ".litter" not in app_identifier.lower():
            continue
        if not entitlements.get("get-task-allow", False):
            continue
        expiration = profile.get("ExpirationDate")
        if not expiration or expiration <= datetime.datetime.now():
            continue
        cert_hashes = [
            hashlib.sha1(cert).hexdigest().upper()
            for cert in profile.get("DeveloperCertificates", [])
        ]
        cert_hash = next((value for value in cert_hashes if value in identity_output), "")
        if not cert_hash:
            continue
        team_ids = profile.get("TeamIdentifier", [])
        team_id = team_ids[0] if team_ids else app_identifier.split(".", 1)[0]
        prefix = f"{team_id}."
        bundle_id = app_identifier[len(prefix):] if app_identifier.startswith(prefix) else ""
        if not bundle_id:
            continue
        candidates.append(
            (
                expiration,
                real_path,
                profile.get("UUID", ""),
                bundle_id,
                team_id,
                cert_hash,
                decoded,
            )
        )
    except (OSError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        continue

if not candidates:
    sys.exit(1)

expiration, path, uuid, bundle_id, team_id, cert_hash, decoded = max(
    candidates, key=lambda item: item[0]
)
with open(output_path, "w", encoding="utf-8") as fh:
    for value in (path, uuid, bundle_id, team_id, cert_hash):
        fh.write(value + "\n")
PY

if [[ ! -s "${PROFILE_INFO}" ]]; then
  echo "ERROR: no valid Litter iOS development profile matches an installed signing identity." >&2
  echo "       Set IOS_LOCAL_PROVISIONING_PROFILE to a valid .mobileprovision file." >&2
  exit 1
fi

LOCAL_PROFILE="$(sed -n '1p' "${PROFILE_INFO}")"
PROFILE_UUID="$(sed -n '2p' "${PROFILE_INFO}")"
LOCAL_BUNDLE_ID="$(sed -n '3p' "${PROFILE_INFO}")"
LOCAL_TEAM_ID="$(sed -n '4p' "${PROFILE_INFO}")"
SIGNING_IDENTITY="$(sed -n '5p' "${PROFILE_INFO}")"

PROFILE_STORE="${HOME}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "${PROFILE_STORE}"
STORED_PROFILE="${PROFILE_STORE}/${PROFILE_UUID}.mobileprovision"
if [[ "${LOCAL_PROFILE}" != "${STORED_PROFILE}" ]]; then
  cp "${LOCAL_PROFILE}" "${STORED_PROFILE}"
fi

echo "==> Building unsigned device app for local signing..."
unsigned_args=(
  xcodebuild
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "generic/platform=iOS"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  COMPILER_INDEX_STORE_ENABLE=NO
)
if [[ "${ONLY_ACTIVE_ARCH}" == "1" ]]; then
  unsigned_args+=(ONLY_ACTIVE_ARCH=YES)
fi
unsigned_args+=(build)
"${unsigned_args[@]}"

APP_PATH="$(xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=iOS" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR = / { target_dir=$2 } / WRAPPER_NAME = / { wrapper=$2 } END { if (target_dir && wrapper) print target_dir "/" wrapper }')"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" || "${APP_PATH}" != *"/Litter.app" ]]; then
  echo "ERROR: could not resolve the unsigned Litter.app output." >&2
  exit 1
fi

# A single local app profile cannot sign the optional watch/live-activity
# bundles. The main phone app remains fully functional without them.
rm -rf "${APP_PATH}/PlugIns" "${APP_PATH}/Watch"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${LOCAL_BUNDLE_ID}" "${APP_PATH}/Info.plist"
cp "${LOCAL_PROFILE}" "${APP_PATH}/embedded.mobileprovision"

security cms -D -i "${LOCAL_PROFILE}" \
  | plutil -extract Entitlements xml1 -o "${ENTITLEMENTS_PLIST}" -

while IFS= read -r -d '' signable; do
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp=none "${signable}"
done < <(find "${APP_PATH}/Frameworks" \
  \( -type d -name '*.framework' -print0 -prune -o -type f -name '*.dylib' -print0 \) \
  2>/dev/null)

while IFS= read -r -d '' dylib; do
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp=none "${dylib}"
done < <(find "${APP_PATH}" -type f -name '*.dylib' -print0)

codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --entitlements "${ENTITLEMENTS_PLIST}" \
  --timestamp=none \
  --generate-entitlement-der \
  "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"

mkdir -p "${SIGNING_STATE_DIR}"
touch "${LOCAL_SIGNING_MARKER}"

echo "==> Locally signed ${LOCAL_BUNDLE_ID} for team ${LOCAL_TEAM_ID}"
echo "==> Device app: ${APP_PATH}"
