#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_TEMP_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}"
umask 077

required=(
    ANDROID_UPLOAD_KEYSTORE_B64
    LITTER_UPLOAD_STORE_PASSWORD
    LITTER_UPLOAD_KEY_ALIAS
    LITTER_UPLOAD_KEY_PASSWORD
    LITTER_PLAY_SERVICE_ACCOUNT_JSON_B64
)
for name in "${required[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required secret: $name" >&2
        exit 1
    fi
done

keystore="$RELEASE_TEMP_DIR/litter-upload.jks"
printf '%s' "$ANDROID_UPLOAD_KEYSTORE_B64" | base64 --decode > "$keystore"
keytool -list \
    -keystore "$keystore" \
    -storepass "$LITTER_UPLOAD_STORE_PASSWORD" \
    -alias "$LITTER_UPLOAD_KEY_ALIAS" >/dev/null
keytool -importkeystore \
    -srckeystore "$keystore" \
    -srcstorepass "$LITTER_UPLOAD_STORE_PASSWORD" \
    -srcalias "$LITTER_UPLOAD_KEY_ALIAS" \
    -srckeypass "$LITTER_UPLOAD_KEY_PASSWORD" \
    -destkeystore "$RELEASE_TEMP_DIR/upload-key-validation.p12" \
    -deststoretype PKCS12 \
    -deststorepass release-preflight-only \
    -destkeypass release-preflight-only \
    -noprompt >/dev/null

service_account_json="$RELEASE_TEMP_DIR/play-service-account.json"
if printf '%s' "$LITTER_PLAY_SERVICE_ACCOUNT_JSON_B64" | base64 --decode 2>/dev/null > "$service_account_json" \
    && python3 -m json.tool "$service_account_json" >/dev/null 2>&1; then
    :
else
    printf '%s' "$LITTER_PLAY_SERVICE_ACCOUNT_JSON_B64" > "$service_account_json"
    python3 -m json.tool "$service_account_json" >/dev/null
fi

python3 "$SCRIPT_DIR/fetch-mobile-store-artifacts.py" \
    --check-play-access \
    --play-service-account-json "$service_account_json" \
    --android-package com.sigkitten.litter.android
