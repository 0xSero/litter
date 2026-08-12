#!/usr/bin/env bash
#
# Generate Swift/Kotlin bindings from codex-mobile-client.
#
# Usage:  ./generate-bindings.sh [--release] [--swift-only] [--kotlin-only]
#
# Outputs:
#   generated/swift/   — Swift source files
#   generated/kotlin/  — Kotlin source files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$SCRIPT_DIR"
source "$WORKSPACE_DIR/../../tools/scripts/load-sccache-aws-creds.sh"
OUT_SWIFT="$WORKSPACE_DIR/generated/swift"
OUT_KOTLIN="$WORKSPACE_DIR/generated/kotlin"
SWIFT_BINDINGS_HASH_FILE="$WORKSPACE_DIR/../../apps/ios/GeneratedRust/.swift-bindings.hash"
BINDINGS_HASH_SCRIPT="$WORKSPACE_DIR/../../tools/scripts/uniffi-bindings-input-hash.sh"

cd "$WORKSPACE_DIR"

if [[ -z "${RUSTC_WRAPPER:-}" ]] && [[ "${CARGO_INCREMENTAL:-}" != "1" ]] && command -v sccache >/dev/null 2>&1; then
    sccache_path="$(command -v sccache)"
    export RUSTC_WRAPPER="$sccache_path"
fi

"$WORKSPACE_DIR/../../tools/scripts/update-alleycat-main.sh" --shared

PROFILE="debug"
GENERATE_SWIFT=1
GENERATE_KOTLIN=1

for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            ;;
        --swift-only)
            GENERATE_KOTLIN=0
            ;;
        --kotlin-only)
            GENERATE_SWIFT=0
            ;;
        *)
            echo "usage: $(basename "$0") [--release] [--swift-only] [--kotlin-only]" >&2
            exit 1
            ;;
    esac
done

if [[ "$GENERATE_SWIFT" -eq 0 && "$GENERATE_KOTLIN" -eq 0 ]]; then
    echo "error: nothing to generate" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Build the cdylib so uniffi-bindgen can read its metadata
# ---------------------------------------------------------------------------
echo "==> Building codex-mobile-client cdylib ($PROFILE)..."

if [[ "$PROFILE" == "release" ]]; then
    cargo build -p codex-mobile-client --release
else
    cargo build -p codex-mobile-client
fi

DYLIB_PATH="${CARGO_TARGET_DIR:-$WORKSPACE_DIR/target}/$PROFILE"

# Resolve the dynamic library name per platform
if [[ "$(uname)" == "Darwin" ]]; then
    DYLIB_FILE="$DYLIB_PATH/libcodex_mobile_client.dylib"
else
    DYLIB_FILE="$DYLIB_PATH/libcodex_mobile_client.so"
fi

if [[ ! -f "$DYLIB_FILE" ]]; then
    echo "ERROR: Could not find built library at $DYLIB_FILE" >&2
    exit 1
fi

if [[ "$GENERATE_SWIFT" -eq 1 ]]; then
    echo "==> Generating Swift bindings -> $OUT_SWIFT"
    mkdir -p "$OUT_SWIFT"
    rm -f \
        "$OUT_SWIFT/codex_app_server_protocol.swift" \
        "$OUT_SWIFT/codex_app_server_protocolFFI.h" \
        "$OUT_SWIFT/codex_app_server_protocolFFI.modulemap" \
        "$OUT_SWIFT/codex_protocol.swift" \
        "$OUT_SWIFT/codex_protocolFFI.h" \
        "$OUT_SWIFT/codex_protocolFFI.modulemap"
    cargo run -p uniffi-bindgen -- generate \
        --library "$DYLIB_FILE" \
        --language swift \
        --out-dir "$OUT_SWIFT"
    cp "$OUT_SWIFT/codex_mobile_clientFFI.modulemap" "$OUT_SWIFT/module.modulemap"
    mkdir -p "$(dirname "$SWIFT_BINDINGS_HASH_FILE")"
    "$BINDINGS_HASH_SCRIPT" >"$SWIFT_BINDINGS_HASH_FILE"
fi

if [[ "$GENERATE_KOTLIN" -eq 1 ]]; then
    echo "==> Generating Kotlin bindings -> $OUT_KOTLIN"
    mkdir -p "$OUT_KOTLIN"
    rm -rf \
        "$OUT_KOTLIN/uniffi/codex_app_server_protocol" \
        "$OUT_KOTLIN/uniffi/codex_protocol"
    cargo run -p uniffi-bindgen -- generate \
        --library "$DYLIB_FILE" \
        --language kotlin \
        --config "$WORKSPACE_DIR/uniffi.toml" \
        --no-format \
        --out-dir "$OUT_KOTLIN"
fi

echo "==> Done. Generated bindings:"
if [[ "$GENERATE_SWIFT" -eq 1 && "$GENERATE_KOTLIN" -eq 1 ]]; then
    find "$OUT_SWIFT" "$OUT_KOTLIN" -type f | sort
elif [[ "$GENERATE_SWIFT" -eq 1 ]]; then
    find "$OUT_SWIFT" -type f | sort
else
    find "$OUT_KOTLIN" -type f | sort
fi
