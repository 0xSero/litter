#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUST_BRIDGE_DIR="$REPO_DIR/shared/rust-bridge"

bindings_inputs() {
  {
  printf '%s\n' \
    "$RUST_BRIDGE_DIR/codex-mobile-client/src/lib.rs" \
    "$RUST_BRIDGE_DIR/codex-mobile-client/src/conversation_uniffi.rs" \
    "$RUST_BRIDGE_DIR/codex-mobile-client/src/discovery_uniffi.rs" \
    "$RUST_BRIDGE_DIR/codex-mobile-client/src/uniffi_shared.rs" \
    "$RUST_BRIDGE_DIR/codex-mobile-client/Cargo.toml" \
    "$RUST_BRIDGE_DIR/Cargo.lock" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/app-server-protocol/src/protocol/common.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/app-server-protocol/src/protocol/v1.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/app-server-protocol/src/protocol/v2.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/protocol/src/account.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/protocol/src/config_types.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/protocol/src/models.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/protocol/src/openai_models.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/protocol/src/parse_command.rs" \
    "$REPO_DIR/shared/third_party/codex/codex-rs/protocol/src/protocol.rs"
    find "$RUST_BRIDGE_DIR/codex-mobile-client/src" -type f -name '*.rs'
  } | sort -u
}

if [ "${1:-}" = "--newer-than" ]; then
  stamp="${2:?usage: $(basename "$0") [--newer-than STAMP]}"
  while IFS= read -r file; do
    if [ -f "$file" ] && { [ ! -e "$stamp" ] || [ "$file" -nt "$stamp" ]; }; then
      exit 0
    fi
  done < <(bindings_inputs)
  exit 1
fi

bindings_inputs | while IFS= read -r file; do
  [ -f "$file" ] || continue
  shasum -a 256 "$file"
done | shasum -a 256 | awk '{print $1}'
