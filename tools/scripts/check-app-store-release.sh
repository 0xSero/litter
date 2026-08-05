#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE_TEMP_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}"
REQUIRE_WATCH_PROFILES="${REQUIRE_WATCH_PROFILES:-0}"
BETA_APP_DESCRIPTION_FILE="${BETA_APP_DESCRIPTION_FILE:-$REPO_ROOT/docs/releases/testflight-beta-description.txt}"
umask 077

if [[ ! -s "$BETA_APP_DESCRIPTION_FILE" ]] ||
    ! grep -q '[^[:space:]]' "$BETA_APP_DESCRIPTION_FILE"; then
    echo "Missing TestFlight Beta App Description: $BETA_APP_DESCRIPTION_FILE" >&2
    exit 1
fi

required=(
    ASC_KEY_ID
    ASC_ISSUER_ID
    ASC_PRIVATE_KEY_P8_B64
    IOS_APP_STORE_APP_ID
    IOS_TEAM_ID
    IOS_DIST_CERT_P12_B64
    IOS_DIST_CERT_PASSWORD
    IOS_APP_STORE_PROFILE_B64
    IOS_LIVE_ACTIVITY_APP_STORE_PROFILE_B64
)
if [[ "$REQUIRE_WATCH_PROFILES" == "1" ]]; then
    required+=(IOS_WATCH_APP_STORE_PROFILE_B64 IOS_WATCH_COMPLICATIONS_APP_STORE_PROFILE_B64)
fi
for name in "${required[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required secret: $name" >&2
        exit 1
    fi
done

key_path="$RELEASE_TEMP_DIR/AuthKey_${ASC_KEY_ID}.p8"
printf '%s' "$ASC_PRIVATE_KEY_P8_B64" | base64 --decode > "$key_path"
chmod 600 "$key_path"
openssl pkey -in "$key_path" -noout
export ASC_PRIVATE_KEY_PATH="$key_path"

cert_path="$RELEASE_TEMP_DIR/dist-cert.p12"
app_profile_path="$RELEASE_TEMP_DIR/app-store.mobileprovision"
activity_profile_path="$RELEASE_TEMP_DIR/live-activity-app-store.mobileprovision"
printf '%s' "$IOS_DIST_CERT_P12_B64" | base64 --decode > "$cert_path"
printf '%s' "$IOS_APP_STORE_PROFILE_B64" | base64 --decode > "$app_profile_path"
printf '%s' "$IOS_LIVE_ACTIVITY_APP_STORE_PROFILE_B64" | base64 --decode > "$activity_profile_path"
openssl pkcs12 -in "$cert_path" -passin env:IOS_DIST_CERT_PASSWORD -noout

validation_keychain_path="$RELEASE_TEMP_DIR/release-validation.keychain-db"
validation_keychain_password="$(openssl rand -base64 24)"
cleanup_validation_keychain() {
    security delete-keychain "$validation_keychain_path" >/dev/null 2>&1 || true
}
trap cleanup_validation_keychain EXIT

security create-keychain -p "$validation_keychain_password" "$validation_keychain_path"
security unlock-keychain -p "$validation_keychain_password" "$validation_keychain_path"
export APPLE_SIGNING_P12_PASSWORD="$IOS_DIST_CERT_PASSWORD"
export APPLE_SIGNING_KEYCHAIN_PASSWORD="$validation_keychain_password"
"$SCRIPT_DIR/import-apple-signing-identity.sh" "$cert_path" "$validation_keychain_path"
if ! security find-identity -v -p codesigning "$validation_keychain_path" |
    grep -Eq '^[[:space:]]*[1-9][0-9]* valid identities found$'; then
    echo "The distribution certificate did not produce a valid macOS codesigning identity." >&2
    exit 1
fi

validate_profile() {
    local profile_path="$1"
    local bundle_id="$2"
    local profile_plist="$profile_path.plist"
    local app_identifier team_identifier

    security cms -D -i "$profile_path" > "$profile_plist"
    app_identifier="$(plutil -extract Entitlements.application-identifier raw -o - "$profile_plist")"
    team_identifier="$(plutil -extract TeamIdentifier.0 raw -o - "$profile_plist")"
    if [[ "$app_identifier" != "$IOS_TEAM_ID.$bundle_id" || "$team_identifier" != "$IOS_TEAM_ID" ]]; then
        echo "Provisioning profile does not match team $IOS_TEAM_ID and bundle $bundle_id" >&2
        exit 1
    fi
}

validate_profile "$app_profile_path" com.sigkitten.litter
validate_profile "$activity_profile_path" com.sigkitten.litter.activity
if [[ "$REQUIRE_WATCH_PROFILES" == "1" ]]; then
    watch_profile_path="$RELEASE_TEMP_DIR/watch-app-store.mobileprovision"
    watch_comp_profile_path="$RELEASE_TEMP_DIR/watch-complications-app-store.mobileprovision"
    printf '%s' "$IOS_WATCH_APP_STORE_PROFILE_B64" | base64 --decode > "$watch_profile_path"
    printf '%s' "$IOS_WATCH_COMPLICATIONS_APP_STORE_PROFILE_B64" | base64 --decode > "$watch_comp_profile_path"
    validate_profile "$watch_profile_path" com.sigkitten.litter.watch
    validate_profile "$watch_comp_profile_path" com.sigkitten.litter.watch.complications
fi

asc apps list --bundle-id com.sigkitten.litter --output json |
    python3 -c 'import json, os, sys; data=json.load(sys.stdin).get("data", []); raise SystemExit(not any(app.get("id") == os.environ["IOS_APP_STORE_APP_ID"] for app in data))'
