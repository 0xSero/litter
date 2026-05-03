#!/usr/bin/env bash
# Mac Catalyst TestFlight upload — companion to testflight-upload.sh.
#
# Differences from the iOS flow:
#   * Archives the `LitterMac` scheme with destination
#     `generic/platform=macOS,variant=Mac Catalyst` → produces a `.pkg`.
#   * No Live Activity widget to sign (stripped from LitterMac target).
#   * Uploads via `asc builds upload --pkg`; asc auto-sets platform=MAC_OS.
#
# Shares the same MARKETING_VERSION + What-to-Test file as the iOS build so
# a TestFlight cycle can submit both platforms at the repo's current version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

SCHEME="${SCHEME:-LitterMac}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_DIR="${PROJECT_DIR:-$IOS_DIR}"
PROJECT_PATH="${PROJECT_PATH:-$PROJECT_DIR/Litter.xcodeproj}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_STORE_APP_ID="${APP_STORE_APP_ID:-}"
TEAM_ID="${TEAM_ID:-}"
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-Litter Mac App Store}"
APP_PROVISIONING_PROFILE_SPECIFIER="${APP_PROVISIONING_PROFILE_SPECIFIER:-$PROVISIONING_PROFILE_SPECIFIER}"
APP_CODE_SIGN_IDENTITY="${APP_CODE_SIGN_IDENTITY:-Apple Distribution}"
INSTALLER_CODE_SIGN_IDENTITY="${INSTALLER_CODE_SIGN_IDENTITY:-3rd Party Mac Developer Installer}"
# Manual signing is required here so xcodebuild doesn't auto-pick the iOS
# `Litter` distribution profile (same bundle ID, no sandbox entitlement) and
# strip `com.apple.security.app-sandbox` from the Mac binary at export time —
# which is what caused ITMS-90296 on v1.0.4/build 20260226153278.
EXPORT_SIGNING_STYLE="${EXPORT_SIGNING_STYLE:-manual}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
ASSIGN_BETA_GROUP="${ASSIGN_BETA_GROUP:-1}"
INTERNAL_BETA_GROUP_NAME="${INTERNAL_BETA_GROUP_NAME:-Internal Testers}"
EXTERNAL_BETA_GROUP_NAME="${EXTERNAL_BETA_GROUP_NAME:-Beta Testers}"
LEGACY_BETA_GROUP_NAME="${BETA_GROUP_NAME:-}"
if [[ -n "${BETA_GROUP_NAMES:-}" ]]; then
    BETA_GROUP_NAMES="${BETA_GROUP_NAMES}"
elif [[ -n "$LEGACY_BETA_GROUP_NAME" ]]; then
    BETA_GROUP_NAMES="$LEGACY_BETA_GROUP_NAME"
else
    BETA_GROUP_NAMES="$INTERNAL_BETA_GROUP_NAME,$EXTERNAL_BETA_GROUP_NAME"
fi
SUBMIT_BETA_REVIEW="${SUBMIT_BETA_REVIEW:-1}"
WAIT_FOR_PROCESSING="${WAIT_FOR_PROCESSING:-1}"
BUILD_POLL_TIMEOUT_SECONDS="${BUILD_POLL_TIMEOUT_SECONDS:-900}"
BUILD_POLL_INTERVAL_SECONDS="${BUILD_POLL_INTERVAL_SECONDS:-15}"
WHAT_TO_TEST="${WHAT_TO_TEST:-}"
WHAT_TO_TEST_LOCALE="${WHAT_TO_TEST_LOCALE:-en-US}"
WHAT_TO_TEST_FILE="${WHAT_TO_TEST_FILE:-$TESTFLIGHT_WHATS_NEW_FILE}"
AUTO_GENERATE_WHAT_TO_TEST="${AUTO_GENERATE_WHAT_TO_TEST:-1}"
WHAT_TO_TEST_MAX_COMMITS="${WHAT_TO_TEST_MAX_COMMITS:-8}"
AUTO_ASSIGN_ENCRYPTION_DECLARATION="${AUTO_ASSIGN_ENCRYPTION_DECLARATION:-1}"
TESTFLIGHT_SKIP_BUILD="${TESTFLIGHT_SKIP_BUILD:-0}"
TESTFLIGHT_SKIP_UPLOAD="${TESTFLIGHT_SKIP_UPLOAD:-0}"
XCODE_ARCHIVE_TIMEOUT_SECONDS="${XCODE_ARCHIVE_TIMEOUT_SECONDS:-3600}"
XCODE_EXPORT_TIMEOUT_SECONDS="${XCODE_EXPORT_TIMEOUT_SECONDS:-1800}"
# Version bump is owned by the iOS script — it runs first in a shared
# release and advances MARKETING_VERSION in project.yml once per cycle.
# The Mac script just reads the current value.
TESTFLIGHT_AUTO_BUMP_VERSION="${TESTFLIGHT_AUTO_BUMP_VERSION:-0}"

AUTH_KEY_PATH="${AUTH_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
AUTH_KEY_ID="${AUTH_KEY_ID:-${ASC_KEY_ID:-}}"
AUTH_ISSUER_ID="${AUTH_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build/testflight-mac}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
PKG_PATH="$BUILD_DIR/$SCHEME.pkg"
BUILD_METADATA_PATH="${BUILD_METADATA_PATH:-$BUILD_DIR/testflight-mac-build.env}"

require_cmd asc
require_cmd jq
require_cmd xcodebuild
require_cmd xcodegen

mkdir -p "$BUILD_DIR"

if [[ "$TESTFLIGHT_SKIP_BUILD" == "1" && -f "$BUILD_METADATA_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$BUILD_METADATA_PATH"
elif [[ "$TESTFLIGHT_SKIP_BUILD" == "1" ]]; then
    echo "Missing build metadata at $BUILD_METADATA_PATH for TESTFLIGHT_SKIP_BUILD=1." >&2
    exit 1
fi

persist_build_metadata() {
    cat >"$BUILD_METADATA_PATH" <<EOF
BUILD_NUMBER=$(printf '%q' "$BUILD_NUMBER")
APP_STORE_APP_ID=$(printf '%q' "$APP_STORE_APP_ID")
TEAM_ID=$(printf '%q' "$TEAM_ID")
PROVISIONING_PROFILE_SPECIFIER=$(printf '%q' "$PROVISIONING_PROFILE_SPECIFIER")
APP_PROVISIONING_PROFILE_SPECIFIER=$(printf '%q' "$APP_PROVISIONING_PROFILE_SPECIFIER")
MARKETING_VERSION=$(printf '%q' "$MARKETING_VERSION")
WHAT_TO_TEST_LOCALE=$(printf '%q' "$WHAT_TO_TEST_LOCALE")
EOF
}

run_with_timeout() {
    local label="$1"
    local timeout_seconds="$2"
    shift 2

    "$@" &
    local pid=$!
    local deadline=$(( $(date +%s) + timeout_seconds ))
    local status=0

    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
            echo "ERROR: $label exceeded ${timeout_seconds}s; terminating pid $pid" >&2
            kill -TERM "$pid" 2>/dev/null || true
            sleep 10
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 5
    done

    wait "$pid" || status=$?
    return "$status"
}

APP_STORE_APP_ID="$(resolve_app_store_app_id "$APP_STORE_APP_ID" "$APP_BUNDLE_ID")"
TEAM_ID="$(resolve_team_id "$TEAM_ID" "$PROJECT_PATH" "$SCHEME" "$CONFIGURATION" "$EXPORT_SIGNING_STYLE" "$APP_PROVISIONING_PROFILE_SPECIFIER")"

if [[ "$EXPORT_SIGNING_STYLE" != "automatic" && "$EXPORT_SIGNING_STYLE" != "manual" ]]; then
    echo "Unsupported EXPORT_SIGNING_STYLE: $EXPORT_SIGNING_STYLE" >&2
    echo "Expected 'automatic' or 'manual'." >&2
    exit 1
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "$APP_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "Manual export signing requires APP_PROVISIONING_PROFILE_SPECIFIER." >&2
    exit 1
fi

if [[ -z "$MARKETING_VERSION" ]]; then
    MARKETING_VERSION="$(read_project_marketing_version)"
fi
ensure_semver "$MARKETING_VERSION"

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(resolve_next_build_number "$APP_STORE_APP_ID")"
fi

if [[ -z "$WHAT_TO_TEST" && -f "$WHAT_TO_TEST_FILE" ]]; then
    WHAT_TO_TEST="$(cat "$WHAT_TO_TEST_FILE")"
fi

if [[ -z "$WHAT_TO_TEST" && "$AUTO_GENERATE_WHAT_TO_TEST" == "1" ]]; then
    WHAT_TO_TEST="$(
        git -C "$ROOT_DIR" log --no-merges -n "$WHAT_TO_TEST_MAX_COMMITS" --pretty='- %s' |
            sed '/^[[:space:]]*$/d'
    )"
fi

if [[ -z "$WHAT_TO_TEST" ]]; then
    echo "Missing TestFlight changelog (What to Test)." >&2
    echo "Set WHAT_TO_TEST, or populate $WHAT_TO_TEST_FILE." >&2
    exit 1
fi

persist_build_metadata

auth_args=()
if [[ -n "$AUTH_KEY_PATH" && -n "$AUTH_KEY_ID" && -n "$AUTH_ISSUER_ID" ]]; then
    auth_args=(
        -authenticationKeyPath "$AUTH_KEY_PATH"
        -authenticationKeyID "$AUTH_KEY_ID"
        -authenticationKeyIssuerID "$AUTH_ISSUER_ID"
    )
fi

if [[ "$TESTFLIGHT_SKIP_BUILD" != "1" ]]; then
    echo "==> Regenerating Xcode project"
    "$PROJECT_DIR/scripts/regenerate-project.sh"

    echo "==> Archiving $SCHEME ($MARKETING_VERSION/$BUILD_NUMBER) for Mac Catalyst"
    rm -rf "$DERIVED_DATA_PATH"
    rm -rf "$ARCHIVE_PATH"
    archive_cmd=(
        xcodebuild
        -project "$PROJECT_PATH"
        -scheme "$SCHEME"
        -configuration "$CONFIGURATION"
        -destination "generic/platform=macOS,variant=Mac Catalyst"
        -archivePath "$ARCHIVE_PATH"
        -derivedDataPath "$DERIVED_DATA_PATH"
        -showBuildTimingSummary
        clean archive
        MARKETING_VERSION="$MARKETING_VERSION"
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
        ARCHS=arm64
        ONLY_ACTIVE_ARCH=NO
        SWIFT_COMPILATION_MODE=singlefile
        SWIFT_WHOLE_MODULE_OPTIMIZATION=NO
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
        CLANG_ENABLE_EXPLICIT_MODULES=NO
        COMPILER_INDEX_STORE_ENABLE=NO
    )

    if [[ -n "$TEAM_ID" ]]; then
        archive_cmd+=(DEVELOPMENT_TEAM="$TEAM_ID")
    fi

    if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
        archive_cmd+=(
            APP_CODE_SIGN_STYLE=Manual
            APP_PROVISIONING_PROFILE_SPECIFIER="$APP_PROVISIONING_PROFILE_SPECIFIER"
            APP_CODE_SIGN_IDENTITY="$APP_CODE_SIGN_IDENTITY"
        )
    else
        archive_cmd+=(-allowProvisioningUpdates)
    fi

    if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
        archive_cmd+=("${auth_args[@]}")
    fi

    run_with_timeout "xcodebuild archive" "$XCODE_ARCHIVE_TIMEOUT_SECONDS" "${archive_cmd[@]}"

    # Sandbox-entitlement gate — catches ITMS-90296 before we waste a build
    # slot on App Store Connect.
    archived_app="$ARCHIVE_PATH/Products/Applications/Litter.app"
    if [[ ! -d "$archived_app" ]]; then
        echo "No archived app found at $archived_app — cannot verify entitlements." >&2
        exit 1
    fi
    entitlements_xml="$(codesign -d --entitlements :- "$archived_app" 2>/dev/null || true)"
    if ! grep -q "com\.apple\.security\.app-sandbox" <<<"$entitlements_xml"; then
        echo "ERROR: signed $archived_app is missing com.apple.security.app-sandbox" >&2
        echo "       ASC will reject this with ITMS-90296. Check that APP_PROVISIONING_PROFILE_SPECIFIER" >&2
        echo "       points at the Mac App Store profile (not the iOS Litter distribution profile)." >&2
        exit 1
    fi
    if ! grep -A1 "com\.apple\.security\.app-sandbox" <<<"$entitlements_xml" | grep -q "<true/>"; then
        echo "ERROR: com.apple.security.app-sandbox is present but not <true/> on $archived_app" >&2
        exit 1
    fi
    echo "==> Verified app-sandbox entitlement is present on signed binary"

    cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>${EXPORT_SIGNING_STYLE}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

    if [[ -n "$TEAM_ID" ]]; then
        /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
    fi
    if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $APP_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
        /usr/libexec/PlistBuddy -c "Add :signingCertificate string $APP_CODE_SIGN_IDENTITY" "$EXPORT_OPTIONS_PLIST"
        /usr/libexec/PlistBuddy -c "Add :installerSigningCertificate string $INSTALLER_CODE_SIGN_IDENTITY" "$EXPORT_OPTIONS_PLIST"
    fi

    echo "==> Exporting PKG with xcodebuild -exportArchive (signing: $EXPORT_SIGNING_STYLE)"
    rm -f "$BUILD_DIR"/*.pkg
    export_cmd=(
        xcodebuild
        -exportArchive
        -archivePath "$ARCHIVE_PATH"
        -exportPath "$BUILD_DIR"
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
    )

    if [[ "$EXPORT_SIGNING_STYLE" == "automatic" ]]; then
        export_cmd+=(-allowProvisioningUpdates)
    fi

    if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
        export_cmd+=("${auth_args[@]}")
    fi

    run_with_timeout "xcodebuild -exportArchive" "$XCODE_EXPORT_TIMEOUT_SECONDS" "${export_cmd[@]}"

    exported_pkg="$(find "$BUILD_DIR" -maxdepth 1 -name "*.pkg" | head -n 1)"
    if [[ -z "$exported_pkg" ]]; then
        echo "No PKG produced in $BUILD_DIR" >&2
        exit 1
    fi
    if [[ "$exported_pkg" != "$PKG_PATH" ]]; then
        cp "$exported_pkg" "$PKG_PATH"
    fi

    if [[ ! -f "$PKG_PATH" ]]; then
        echo "No PKG produced at $PKG_PATH" >&2
        exit 1
    fi
    pkgutil --check-signature "$PKG_PATH"
fi

if [[ ! -f "$PKG_PATH" ]]; then
    echo "Expected PKG at $PKG_PATH" >&2
    exit 1
fi

if [[ "$TESTFLIGHT_SKIP_UPLOAD" == "1" ]]; then
    echo "==> Mac TestFlight build prepared"
    echo "    PKG:         $PKG_PATH"
    echo "    Version:     $MARKETING_VERSION"
    echo "    Build:       $BUILD_NUMBER"
    exit 0
fi

echo "==> Uploading PKG to App Store Connect (app: $APP_STORE_APP_ID, platform: MAC_OS)"
upload_cmd=(
    asc builds upload
    --app "$APP_STORE_APP_ID"
    --pkg "$PKG_PATH"
    --version "$MARKETING_VERSION"
    --build-number "$BUILD_NUMBER"
    --output json
)
if [[ "$WAIT_FOR_PROCESSING" == "1" ]]; then
    upload_cmd+=(--wait)
fi

if ! upload_json="$("${upload_cmd[@]}")"; then
    echo "TestFlight upload failed for version $MARKETING_VERSION / build $BUILD_NUMBER." >&2
    exit 1
fi
echo "$upload_json" >"$BUILD_DIR/upload_result.json"

build_id="$(
    echo "$upload_json" |
        jq -r '.data.id // .data[0].id // empty'
)"
if [[ -z "$build_id" ]]; then
    build_id="$(find_build_id "$APP_STORE_APP_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" 20)"
fi

if [[ -z "$build_id" && "$ASSIGN_BETA_GROUP" == "1" ]]; then
    deadline="$(( $(date +%s) + BUILD_POLL_TIMEOUT_SECONDS ))"
    while [[ -z "$build_id" && "$(date +%s)" -lt "$deadline" ]]; do
        sleep "$BUILD_POLL_INTERVAL_SECONDS"
        build_id="$(find_build_id "$APP_STORE_APP_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" 50)"
    done
fi

if [[ -n "$build_id" && "$AUTO_ASSIGN_ENCRYPTION_DECLARATION" == "1" ]]; then
    internal_state="$(
        asc builds build-beta-detail view --build-id "$build_id" --output json |
            jq -r '.data.attributes.internalBuildState // empty'
    )"
    if [[ "$internal_state" == "MISSING_EXPORT_COMPLIANCE" ]]; then
        declaration_id="$(
            asc encryption declarations list --app "$APP_STORE_APP_ID" --output json |
                jq -r '.data | sort_by(.attributes.createdDate // "") | last | .id // empty'
        )"
        if [[ -n "$declaration_id" ]]; then
            echo "==> Assigning build $build_id to encryption declaration $declaration_id"
            asc encryption declarations assign-builds \
                --id "$declaration_id" \
                --build "$build_id" \
                --output json >/dev/null || true
        fi
    fi
fi

if [[ -n "$build_id" && -n "$WHAT_TO_TEST" ]]; then
    echo "==> Ensuring What to Test notes are set for $WHAT_TO_TEST_LOCALE"
    if ! asc builds test-notes update \
            --build-id "$build_id" \
            --locale "$WHAT_TO_TEST_LOCALE" \
            --whats-new "$WHAT_TO_TEST" \
            --output json >/dev/null 2>&1; then
        asc builds test-notes create \
            --build-id "$build_id" \
            --locale "$WHAT_TO_TEST_LOCALE" \
            --whats-new "$WHAT_TO_TEST" \
            --output json >/dev/null
    fi
fi

if [[ "$ASSIGN_BETA_GROUP" == "1" && -n "$build_id" ]]; then
    beta_group_ids=()
    external_group_requested=0
    beta_review_submit_attempted=0
    beta_review_submit_succeeded=0

    IFS=',' read -r -a requested_group_names <<<"$BETA_GROUP_NAMES"
    for raw_group_name in "${requested_group_names[@]}"; do
        group_name="$(trim "$raw_group_name")"
        [[ -n "$group_name" ]] || continue

        beta_group_id="$(
            asc testflight groups list --app "$APP_STORE_APP_ID" --output json |
                jq -r --arg name "$group_name" '.data[] | select(.attributes.name == $name) | .id' |
                head -n 1
        )"

        if [[ -z "$beta_group_id" ]]; then
            create_cmd=(
                asc testflight groups create
                --app "$APP_STORE_APP_ID"
                --name "$group_name"
                --output json
            )
            if [[ "$group_name" == "$INTERNAL_BETA_GROUP_NAME" ]]; then
                create_cmd+=(--internal)
            else
                external_group_requested=1
            fi
            beta_group_id="$(
                "${create_cmd[@]}" |
                    jq -r '.data.id // empty'
            )"
        elif [[ "$group_name" != "$INTERNAL_BETA_GROUP_NAME" ]]; then
            external_group_requested=1
        fi

        if [[ -n "$beta_group_id" ]]; then
            beta_group_ids+=("$beta_group_id")
        fi
    done

    if [[ "${#beta_group_ids[@]}" -gt 0 ]]; then
        group_csv="$(IFS=,; printf '%s' "${beta_group_ids[*]}")"
        echo "==> Assigning build $build_id to beta groups: $BETA_GROUP_NAMES"
        deadline="$(( $(date +%s) + BUILD_POLL_TIMEOUT_SECONDS ))"
        assigned=0
        while [[ "$(date +%s)" -lt "$deadline" ]]; do
            if asc builds add-groups --build-id "$build_id" --group "$group_csv" --output json >/dev/null 2>&1; then
                assigned=1
                break
            fi
            sleep "$BUILD_POLL_INTERVAL_SECONDS"
        done
        if [[ "$assigned" -ne 1 ]]; then
            echo "Failed to assign build $build_id to beta groups '$BETA_GROUP_NAMES' within timeout." >&2
            exit 1
        fi

        if [[ "$SUBMIT_BETA_REVIEW" == "1" && "$external_group_requested" -eq 1 ]]; then
            echo "==> Submitting build $build_id for Beta App Review"
            beta_review_submit_attempted=1
            submit_log="$BUILD_DIR/beta-review-submit.log"
            rm -f "$submit_log"
            for attempt in 1 2 3; do
                if asc testflight review submit --build-id "$build_id" --confirm --output json >"$submit_log" 2>&1; then
                    beta_review_submit_succeeded=1
                    break
                fi
                if [[ "$attempt" -lt 3 ]]; then
                    echo "Beta App Review submit failed on attempt $attempt; retrying..." >&2
                    sleep "$BUILD_POLL_INTERVAL_SECONDS"
                fi
            done
            if [[ "$beta_review_submit_succeeded" -ne 1 ]]; then
                echo "WARNING: Beta App Review submit failed after upload and group assignment." >&2
                echo "         App Store Connect accepted build $build_id; leaving CI green so the build is not lost." >&2
                sed 's/^/         /' "$submit_log" >&2 || true
            fi
        fi
    fi
fi

if [[ -n "$build_id" ]]; then
    echo "==> Validating TestFlight readiness"
    validate_log="$BUILD_DIR/testflight-validate.log"
    if ! asc validate testflight --app "$APP_STORE_APP_ID" --build "$build_id" --strict --output json >"$validate_log" 2>&1; then
        if [[ "${beta_review_submit_attempted:-0}" == "1" && "${beta_review_submit_succeeded:-0}" != "1" ]]; then
            echo "WARNING: strict TestFlight validation failed after Beta App Review submit failed." >&2
            echo "         Build $build_id is uploaded and assigned; ASC may need manual/retry review submission." >&2
            sed 's/^/         /' "$validate_log" >&2 || true
        else
            cat "$validate_log" >&2
            exit 1
        fi
    fi
fi

echo "==> Mac TestFlight upload complete"
echo "    App ID:      $APP_STORE_APP_ID"
echo "    Scheme:      $SCHEME"
echo "    Version:     $MARKETING_VERSION"
echo "    Build:       $BUILD_NUMBER"
echo "    PKG:         $PKG_PATH"
if [[ -n "${build_id:-}" ]]; then
    echo "    Build record: $build_id"
fi
