#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_STORE_APP_ID="${APP_STORE_APP_ID:-}"
FASTLANE_METADATA_DIR="${FASTLANE_METADATA_DIR:-$FASTLANE_DIR}"

BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build/appstore}"

require_cmd asc
require_cmd jq

mkdir -p "$BUILD_DIR"

if [[ -z "$MARKETING_VERSION" ]]; then
    MARKETING_VERSION="$(read_project_marketing_version)"
fi
ensure_semver "$MARKETING_VERSION"

validate_fastlane_metadata "$FASTLANE_METADATA_DIR"

APP_STORE_APP_ID="$(resolve_app_store_app_id "$APP_STORE_APP_ID" "$APP_BUNDLE_ID")"

if [[ -n "$BUILD_NUMBER" ]]; then
    echo "==> Looking up build $MARKETING_VERSION ($BUILD_NUMBER)"
    BUILD_ID="$(find_build_id "$APP_STORE_APP_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" 50)"
else
    echo "==> Finding latest build for version $MARKETING_VERSION"
    build_json="$(
        asc builds list \
            --app "$APP_STORE_APP_ID" \
            --version "$MARKETING_VERSION" \
            --limit 1 \
            --sort "-uploadedDate" \
            --output json
    )"
    BUILD_ID="$(echo "$build_json" | jq -r '.data[0].id // empty')"
    BUILD_NUMBER="$(echo "$build_json" | jq -r '.data[0].attributes.version // empty')"
fi

if [[ -z "$BUILD_ID" ]]; then
    echo "No build found in App Store Connect for version $MARKETING_VERSION${BUILD_NUMBER:+ build $BUILD_NUMBER}." >&2
    echo "Upload a TestFlight build first." >&2
    exit 1
fi

echo "==> Using build $BUILD_ID (version $MARKETING_VERSION, build $BUILD_NUMBER)"

VERSION_ID="$(resolve_app_store_version_id "$APP_STORE_APP_ID" "$MARKETING_VERSION")"
if [[ -z "$VERSION_ID" ]]; then
    echo "==> Creating App Store version $MARKETING_VERSION"
    VERSION_ID="$(
        asc versions create \
            --app "$APP_STORE_APP_ID" \
            --version "$MARKETING_VERSION" \
            --platform IOS \
            --release-type AFTER_APPROVAL \
            --output json |
            jq -r '.data.id // empty'
    )"
else
    echo "==> Reusing App Store version $MARKETING_VERSION ($VERSION_ID)"
    asc versions update \
        --version-id "$VERSION_ID" \
        --release-type AFTER_APPROVAL \
        --output json >/dev/null 2>&1 || echo "    (release type already locked, continuing)"
fi

if [[ -z "$VERSION_ID" ]]; then
    echo "Unable to resolve App Store version id for $MARKETING_VERSION" >&2
    exit 1
fi

mkdir -p "$FASTLANE_METADATA_DIR/screenshots"

echo "==> Importing repo-managed App Store metadata"
if ! asc migrate import \
    --app "$APP_STORE_APP_ID" \
    --version-id "$VERSION_ID" \
    --fastlane-dir "$FASTLANE_METADATA_DIR" \
    --output json >/dev/null 2>&1; then
    echo "    (metadata import skipped — version may already be locked)"
fi

echo "==> Attaching build $BUILD_ID to version $VERSION_ID"
asc versions attach-build \
    --version-id "$VERSION_ID" \
    --build "$BUILD_ID" \
    --output json >/dev/null

echo "==> Validating App Store submission readiness"
validate_log="$BUILD_DIR/validation.json"
if ! asc validate \
    --app "$APP_STORE_APP_ID" \
    --version-id "$VERSION_ID" \
    --strict \
    --output json >"$validate_log" 2>&1; then
    cat "$validate_log" >&2
    exit 1
fi

echo "==> Submitting build for App Store review"
SUBMISSION_ID="$(
    asc review submissions-create \
        --app "$APP_STORE_APP_ID" \
        --platform IOS \
        --output json |
        jq -r '.data.id // empty'
)"
if [[ -z "$SUBMISSION_ID" ]]; then
    echo "Failed to create review submission" >&2
    exit 1
fi

asc review items-add \
    --submission "$SUBMISSION_ID" \
    --item-type appStoreVersions \
    --item-id "$VERSION_ID" \
    --output json >/dev/null

asc review submissions-submit \
    --id "$SUBMISSION_ID" \
    --confirm \
    --output json >"$BUILD_DIR/submission_result.json"

echo "==> App Store submission complete"
echo "    App ID:      $APP_STORE_APP_ID"
echo "    Version:     $MARKETING_VERSION"
echo "    Build:       $BUILD_NUMBER"
echo "    Version ID:  $VERSION_ID"
echo "    Build ID:    $BUILD_ID"
