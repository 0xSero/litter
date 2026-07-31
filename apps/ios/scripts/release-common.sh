#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$IOS_DIR/../.." && pwd)"
IOS_PROJECT_YML="${IOS_PROJECT_YML:-$IOS_DIR/project.yml}"
TESTFLIGHT_WHATS_NEW_FILE="${TESTFLIGHT_WHATS_NEW_FILE:-$ROOT_DIR/docs/releases/testflight-whats-new.md}"
FASTLANE_DIR="${FASTLANE_DIR:-$IOS_DIR/fastlane}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_project_marketing_version() {
    local version
    version="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$IOS_PROJECT_YML")"
    if [[ -z "$version" ]]; then
        echo "Unable to read MARKETING_VERSION from $IOS_PROJECT_YML" >&2
        exit 1
    fi
    printf '%s' "$version"
}

ensure_semver() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Expected MARKETING_VERSION to look like x.y.z, got: $version" >&2
        exit 1
    fi
}

next_patch_version() {
    local version="$1"
    local major minor patch
    ensure_semver "$version"
    IFS='.' read -r major minor patch <<<"$version"
    printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

write_project_marketing_version() {
    local next_version="$1"
    ensure_semver "$next_version"
    perl -0pi -e 's/(MARKETING_VERSION:\s*")([^"]+)(")/$1'"$next_version"'$3/' "$IOS_PROJECT_YML"
}

seed_testflight_whats_new_template() {
    local path="${1:-$TESTFLIGHT_WHATS_NEW_FILE}"
    cat >"$path" <<'EOF'
Summary

- Add summary bullets for the next TestFlight cycle.

What to test

- Add validation steps for the next TestFlight cycle.
EOF
}

resolve_team_from_profile() {
    local profile_name="$1"
    local profile_dir
    local profile_path profile_display team_id
    local -a profile_dirs=(
        "$HOME/Library/MobileDevice/Provisioning Profiles"
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    )

    for profile_dir in "${profile_dirs[@]}"; do
        [[ -d "$profile_dir" ]] || continue
        for profile_path in "$profile_dir"/*.mobileprovision; do
            [[ -e "$profile_path" ]] || continue
            profile_display="$(
                security cms -D -i "$profile_path" 2>/dev/null |
                    plutil -extract Name raw - 2>/dev/null || true
            )"
            [[ "$profile_display" == "$profile_name" ]] || continue
            team_id="$(
                security cms -D -i "$profile_path" 2>/dev/null |
                    plutil -extract TeamIdentifier.0 raw - 2>/dev/null || true
            )"
            if [[ -n "$team_id" ]]; then
                echo "$team_id"
                return 0
            fi
        done
    done
    return 1
}

resolve_app_store_app_id() {
    local current_id="$1"
    local bundle_id="$2"

    if [[ -n "$current_id" ]]; then
        printf '%s' "$current_id"
        return 0
    fi

    current_id="$(
        asc apps list --bundle-id "$bundle_id" --output json |
            jq -r '.data[0].id // empty'
    )"
    if [[ -z "$current_id" ]]; then
        echo "Unable to resolve App Store Connect app id for bundle id: $bundle_id" >&2
        exit 1
    fi
    printf '%s' "$current_id"
}

resolve_team_id() {
    local current_team="$1"
    local project_path="$2"
    local scheme="$3"
    local configuration="$4"
    local export_signing_style="$5"
    local provisioning_profile_specifier="$6"

    if [[ -z "$current_team" ]]; then
        current_team="$(
            xcodebuild -project "$project_path" -scheme "$scheme" -configuration "$configuration" -showBuildSettings |
                awk -F' = ' '/ DEVELOPMENT_TEAM = / {print $2; exit}'
        )"
    fi

    if [[ -z "$current_team" && "$export_signing_style" == "manual" ]]; then
        current_team="$(resolve_team_from_profile "$provisioning_profile_specifier" || true)"
    fi

    if [[ -z "$current_team" ]]; then
        echo "Unable to resolve DEVELOPMENT_TEAM for signing." >&2
        echo "Set TEAM_ID explicitly or ensure the project build settings or provisioning profile can resolve it." >&2
        exit 1
    fi

    printf '%s' "$current_team"
}

resolve_next_build_number() {
    local app_store_app_id="$1"
    local latest_build

    latest_build="$(
        asc builds list --app "$app_store_app_id" --limit 1 --sort "-uploadedDate" --output json |
            jq -r '.data[0].attributes.version // empty'
    )"
    if [[ "$latest_build" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((latest_build + 1))"
    else
        date +%Y%m%d%H%M
    fi
}

find_build_id() {
    local app_store_app_id="$1"
    local marketing_version="$2"
    local build_number="$3"
    local limit="${4:-20}"

    asc builds list \
        --app "$app_store_app_id" \
        --version "$marketing_version" \
        --build-number "$build_number" \
        --limit "$limit" \
        --sort "-uploadedDate" \
        --output json |
        jq -r '.data[0].id // empty'
}

testflight_version_requires_bump() {
    local app_store_app_id="$1"
    local marketing_version="$2"
    local states_json state
    local -a locked_states=(
        ACCEPTED
        READY_FOR_REVIEW
        WAITING_FOR_REVIEW
        IN_REVIEW
        READY_FOR_SALE
        PENDING_DEVELOPER_RELEASE
        PENDING_APPLE_RELEASE
        PROCESSING_FOR_DISTRIBUTION
        PROCESSING_FOR_APP_STORE
        PREORDER_READY_FOR_SALE
        REPLACED_WITH_NEW_VERSION
        DEVELOPER_REMOVED_FROM_SALE
        REMOVED_FROM_SALE
    )

    states_json="$(
        asc versions list --app "$app_store_app_id" --version "$marketing_version" --platform IOS --output json |
            jq -r '.data[]? | (.attributes.appStoreState // .attributes.appStoreVersionState // .attributes.state // empty)'
    )"

    while IFS= read -r state; do
        [[ -n "$state" ]] || continue
        for locked_state in "${locked_states[@]}"; do
            if [[ "$state" == "$locked_state" ]]; then
                return 0
            fi
        done
    done <<<"$states_json"

    return 1
}

resolve_app_store_version_id() {
    local app_store_app_id="$1"
    local marketing_version="$2"

    asc versions list --app "$app_store_app_id" --version "$marketing_version" --platform IOS --output json |
        jq -r '.data[0].id // empty'
}

validate_fastlane_metadata() {
    local fastlane_dir="${1:-$FASTLANE_DIR}"
    local locale_dir="$fastlane_dir/metadata/en-US"
    local required_files=(
        "$locale_dir/name.txt"
        "$locale_dir/subtitle.txt"
        "$locale_dir/privacy_url.txt"
        "$locale_dir/description.txt"
        "$locale_dir/keywords.txt"
        "$locale_dir/release_notes.txt"
        "$locale_dir/promotional_text.txt"
        "$locale_dir/support_url.txt"
        "$locale_dir/marketing_url.txt"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -s "$file" ]]; then
            echo "Missing required App Store metadata file: $file" >&2
            exit 1
        fi
    done

    asc migrate validate --fastlane-dir "$fastlane_dir" --output json >/dev/null
}
