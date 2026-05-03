#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

SCHEME="${SCHEME:-Litter}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_DIR="${PROJECT_DIR:-$IOS_DIR}"
PROJECT_PATH="${PROJECT_PATH:-$PROJECT_DIR/Litter.xcodeproj}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_STORE_APP_ID="${APP_STORE_APP_ID:-}"
TEAM_ID="${TEAM_ID:-}"
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-Litter App Store}"
APP_PROVISIONING_PROFILE_SPECIFIER="${APP_PROVISIONING_PROFILE_SPECIFIER:-$PROVISIONING_PROFILE_SPECIFIER}"
LIVE_ACTIVITY_BUNDLE_ID="${LIVE_ACTIVITY_BUNDLE_ID:-com.sigkitten.litter.liveactivity}"
LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER="${LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER:-}"
WATCH_BUNDLE_ID="${WATCH_BUNDLE_ID:-com.sigkitten.litter.watchkitapp}"
WATCH_PROVISIONING_PROFILE_SPECIFIER="${WATCH_PROVISIONING_PROFILE_SPECIFIER:-}"
WATCH_COMP_BUNDLE_ID="${WATCH_COMP_BUNDLE_ID:-com.sigkitten.litter.watchkitapp.complications}"
WATCH_COMP_PROVISIONING_PROFILE_SPECIFIER="${WATCH_COMP_PROVISIONING_PROFILE_SPECIFIER:-}"
APP_CODE_SIGN_IDENTITY="${APP_CODE_SIGN_IDENTITY:-Apple Distribution}"
LIVE_ACTIVITY_CODE_SIGN_IDENTITY="${LIVE_ACTIVITY_CODE_SIGN_IDENTITY:-Apple Distribution}"
WATCH_CODE_SIGN_IDENTITY="${WATCH_CODE_SIGN_IDENTITY:-Apple Distribution}"
WATCH_COMP_CODE_SIGN_IDENTITY="${WATCH_COMP_CODE_SIGN_IDENTITY:-Apple Distribution}"
EXPORT_SIGNING_STYLE="${EXPORT_SIGNING_STYLE:-automatic}"
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
TESTFLIGHT_AUTO_BUMP_VERSION="${TESTFLIGHT_AUTO_BUMP_VERSION:-1}"
PROJECT_VERSION_BUMP_REQUIRED="${PROJECT_VERSION_BUMP_REQUIRED:-0}"
PROJECT_VERSION_BUMP_TARGET="${PROJECT_VERSION_BUMP_TARGET:-}"

AUTH_KEY_PATH="${AUTH_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
AUTH_KEY_ID="${AUTH_KEY_ID:-${ASC_KEY_ID:-}}"
AUTH_ISSUER_ID="${AUTH_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build/testflight}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
IPA_PATH="$BUILD_DIR/$SCHEME.ipa"
BUILD_METADATA_PATH="${BUILD_METADATA_PATH:-$BUILD_DIR/testflight-build.env}"

require_cmd asc
require_cmd jq
require_cmd xcodebuild
require_cmd xcodegen

if [[ -x "$SCRIPT_DIR/sanitize-ios-frameworks.sh" ]]; then
    "$SCRIPT_DIR/sanitize-ios-frameworks.sh"
fi

mkdir -p "$BUILD_DIR"

if [[ "$TESTFLIGHT_SKIP_BUILD" == "1" && -f "$BUILD_METADATA_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$BUILD_METADATA_PATH"
elif [[ "$TESTFLIGHT_SKIP_BUILD" == "1" ]]; then
    echo "Missing build metadata at $BUILD_METADATA_PATH for TESTFLIGHT_SKIP_BUILD=1." >&2
    exit 1
fi

resolve_requested_testflight_version() {
    local project_version resolved_version next_version

    if [[ -n "$MARKETING_VERSION" ]]; then
        ensure_semver "$MARKETING_VERSION"
        PROJECT_VERSION_BUMP_REQUIRED="${PROJECT_VERSION_BUMP_REQUIRED:-0}"
        PROJECT_VERSION_BUMP_TARGET="${PROJECT_VERSION_BUMP_TARGET:-}"
        echo "$MARKETING_VERSION"
        return 0
    fi

    project_version="$(read_project_marketing_version)"
    ensure_semver "$project_version"
    resolved_version="$project_version"
    PROJECT_VERSION_BUMP_REQUIRED=0
    PROJECT_VERSION_BUMP_TARGET=""

    if [[ "$TESTFLIGHT_AUTO_BUMP_VERSION" == "1" ]] && testflight_version_requires_bump "$APP_STORE_APP_ID" "$project_version"; then
        next_version="$(next_patch_version "$project_version")"
        echo "==> Repo version $project_version is already in App Store distribution; using next TestFlight version $next_version" >&2
        resolved_version="$next_version"
        PROJECT_VERSION_BUMP_REQUIRED=1
        PROJECT_VERSION_BUMP_TARGET="$next_version"
    fi

    echo "$resolved_version"
}

persist_build_metadata() {
    cat >"$BUILD_METADATA_PATH" <<EOF
BUILD_NUMBER=$(printf '%q' "$BUILD_NUMBER")
APP_STORE_APP_ID=$(printf '%q' "$APP_STORE_APP_ID")
TEAM_ID=$(printf '%q' "$TEAM_ID")
PROVISIONING_PROFILE_SPECIFIER=$(printf '%q' "$PROVISIONING_PROFILE_SPECIFIER")
APP_PROVISIONING_PROFILE_SPECIFIER=$(printf '%q' "$APP_PROVISIONING_PROFILE_SPECIFIER")
LIVE_ACTIVITY_BUNDLE_ID=$(printf '%q' "$LIVE_ACTIVITY_BUNDLE_ID")
LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER=$(printf '%q' "$LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER")
MARKETING_VERSION=$(printf '%q' "$MARKETING_VERSION")
WHAT_TO_TEST_LOCALE=$(printf '%q' "$WHAT_TO_TEST_LOCALE")
PROJECT_VERSION_BUMP_REQUIRED=$(printf '%q' "$PROJECT_VERSION_BUMP_REQUIRED")
PROJECT_VERSION_BUMP_TARGET=$(printf '%q' "$PROJECT_VERSION_BUMP_TARGET")
EOF
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

if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "$LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "Manual export signing requires LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER." >&2
    exit 1
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "$WATCH_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "Manual export signing requires WATCH_PROVISIONING_PROFILE_SPECIFIER." >&2
    exit 1
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "$WATCH_COMP_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "Manual export signing requires WATCH_COMP_PROVISIONING_PROFILE_SPECIFIER." >&2
    exit 1
fi

MARKETING_VERSION="$(resolve_requested_testflight_version)"

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

    echo "==> Archiving $SCHEME ($MARKETING_VERSION/$BUILD_NUMBER)"
    archive_cmd=(
        xcodebuild
        -project "$PROJECT_PATH"
        -scheme "$SCHEME"
        -configuration "$CONFIGURATION"
        -destination "generic/platform=iOS"
        -archivePath "$ARCHIVE_PATH"
        clean archive
        MARKETING_VERSION="$MARKETING_VERSION"
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    )

    if [[ -n "$TEAM_ID" ]]; then
        archive_cmd+=(DEVELOPMENT_TEAM="$TEAM_ID")
    fi

    if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
        archive_cmd+=(
            APP_CODE_SIGN_STYLE=Manual
            LIVE_ACTIVITY_CODE_SIGN_STYLE=Manual
            WATCH_CODE_SIGN_STYLE=Manual
            WATCH_COMP_CODE_SIGN_STYLE=Manual
            APP_PROVISIONING_PROFILE_SPECIFIER="$APP_PROVISIONING_PROFILE_SPECIFIER"
            LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER="$LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER"
            WATCH_PROVISIONING_PROFILE_SPECIFIER="$WATCH_PROVISIONING_PROFILE_SPECIFIER"
            WATCH_COMP_PROVISIONING_PROFILE_SPECIFIER="$WATCH_COMP_PROVISIONING_PROFILE_SPECIFIER"
            APP_CODE_SIGN_IDENTITY="$APP_CODE_SIGN_IDENTITY"
            LIVE_ACTIVITY_CODE_SIGN_IDENTITY="$LIVE_ACTIVITY_CODE_SIGN_IDENTITY"
            WATCH_CODE_SIGN_IDENTITY="$WATCH_CODE_SIGN_IDENTITY"
            WATCH_COMP_CODE_SIGN_IDENTITY="$WATCH_COMP_CODE_SIGN_IDENTITY"
        )
    else
        archive_cmd+=(-allowProvisioningUpdates)
    fi

    if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
        archive_cmd+=("${auth_args[@]}")
    fi

    "${archive_cmd[@]}"

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
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$LIVE_ACTIVITY_BUNDLE_ID string $LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$WATCH_BUNDLE_ID string $WATCH_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$WATCH_COMP_BUNDLE_ID string $WATCH_COMP_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
    fi

    echo "==> Exporting IPA (signing: $EXPORT_SIGNING_STYLE)"
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

    "${export_cmd[@]}"

    exported_ipa="$(find "$BUILD_DIR" -maxdepth 1 -name "*.ipa" | head -n 1)"
    if [[ -z "$exported_ipa" ]]; then
        echo "No IPA produced in $BUILD_DIR" >&2
        exit 1
    fi
    if [[ "$exported_ipa" != "$IPA_PATH" ]]; then
        cp "$exported_ipa" "$IPA_PATH"
    fi
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Expected IPA at $IPA_PATH" >&2
    exit 1
fi

if [[ "$TESTFLIGHT_SKIP_UPLOAD" == "1" ]]; then
    echo "==> TestFlight build prepared"
    echo "    IPA:         $IPA_PATH"
    echo "    Version:     $MARKETING_VERSION"
    echo "    Build:       $BUILD_NUMBER"
    exit 0
fi

echo "==> Uploading IPA to App Store Connect (app: $APP_STORE_APP_ID)"
upload_cmd=(
    asc builds upload
    --app "$APP_STORE_APP_ID"
    --ipa "$IPA_PATH"
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
    # Try update first (works if localization already exists), fall back to create.
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
            asc testflight review submit --build-id "$build_id" --confirm --output json >/dev/null
        fi
    fi
fi

if [[ -n "$build_id" ]]; then
    echo "==> Validating TestFlight readiness"
    asc validate testflight --app "$APP_STORE_APP_ID" --build "$build_id" --strict --output json >/dev/null
fi

if [[ "$PROJECT_VERSION_BUMP_REQUIRED" == "1" ]]; then
    echo "==> Updating repo version to $PROJECT_VERSION_BUMP_TARGET for the next beta cycle"
    write_project_marketing_version "$PROJECT_VERSION_BUMP_TARGET"
    seed_testflight_whats_new_template "$WHAT_TO_TEST_FILE"
fi

echo "==> TestFlight upload complete"
echo "    App ID:      $APP_STORE_APP_ID"
echo "    Scheme:      $SCHEME"
echo "    Version:     $MARKETING_VERSION"
echo "    Build:       $BUILD_NUMBER"
echo "    IPA:         $IPA_PATH"
if [[ -n "${build_id:-}" ]]; then
    echo "    Build record: $build_id"
fi
if [[ "$PROJECT_VERSION_BUMP_REQUIRED" == "1" ]]; then
    echo "    Next repo version: $PROJECT_VERSION_BUMP_TARGET"
fi
