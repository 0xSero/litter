#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 <identity.p12> <keychain>" >&2
    exit 2
fi

: "${APPLE_SIGNING_P12_PASSWORD:?APPLE_SIGNING_P12_PASSWORD is required}"
: "${APPLE_SIGNING_KEYCHAIN_PASSWORD:?APPLE_SIGNING_KEYCHAIN_PASSWORD is required}"

p12_path="$1"
keychain_path="$2"
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
identity_pem="$(mktemp "$temp_root/litter-signing-identity.XXXXXX")"

cleanup() {
    rm -f "$identity_pem"
}
trap cleanup EXIT

umask 077
openssl pkcs12 \
    -in "$p12_path" \
    -passin env:APPLE_SIGNING_P12_PASSWORD \
    -nodes \
    -out "$identity_pem"

security import "$identity_pem" \
    -k "$keychain_path" \
    -T /usr/bin/codesign \
    -T /usr/bin/security
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$APPLE_SIGNING_KEYCHAIN_PASSWORD" \
    "$keychain_path"
