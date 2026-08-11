#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE="all"
case "${1:-}" in
  "")
    ;;
  --all|--shared|--kittylitter)
    MODE="${1#--}"
    ;;
  *)
    echo "usage: $(basename "$0") [--all|--shared|--kittylitter]" >&2
    exit 1
    ;;
esac

if [ "${LITTER_SKIP_ALLEYCAT_UPDATE:-0}" = "1" ]; then
  echo "==> Skipping Alleycat main refresh (LITTER_SKIP_ALLEYCAT_UPDATE=1)"
  exit 0
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required" >&2
  exit 1
fi

ALLEYCAT_MAIN_SHA=""

resolve_alleycat_main() {
  if [ -n "$ALLEYCAT_MAIN_SHA" ]; then
    return
  fi

  ALLEYCAT_MAIN_SHA="$(
    git ls-remote https://github.com/dnakov/alleycat.git refs/heads/main \
      | awk '{ print $1; exit }'
  )"
  if [ -z "$ALLEYCAT_MAIN_SHA" ]; then
    echo "error: could not resolve dnakov/alleycat main" >&2
    exit 1
  fi
}

alleycat_is_pinned() {
  grep -q 'dnakov/alleycat\.git.*rev = ' "$1"
}

update_shared() {
  if alleycat_is_pinned "$REPO_DIR/shared/rust-bridge/Cargo.toml"; then
    echo "==> shared Rust Alleycat dependencies are revision-pinned; skipping"
    return
  fi
  resolve_alleycat_main
  echo "==> Resolving shared Rust Alleycat deps to dnakov/alleycat main ($ALLEYCAT_MAIN_SHA)..."
  for package in \
    alleycat-bridge-core \
    alleycat-pi-bridge \
    alleycat-claude-bridge \
    alleycat-opencode-bridge
  do
    cargo update \
      --quiet \
      --manifest-path "$REPO_DIR/shared/rust-bridge/Cargo.toml" \
      -p "$package" \
      --precise "$ALLEYCAT_MAIN_SHA"
  done
}

update_kittylitter() {
  if alleycat_is_pinned "$REPO_DIR/services/kittylitter/Cargo.toml"; then
    echo "==> kittylitter Alleycat dependency is revision-pinned; skipping"
    return
  fi
  resolve_alleycat_main
  echo "==> Resolving kittylitter Alleycat dep to dnakov/alleycat main ($ALLEYCAT_MAIN_SHA)..."
  cargo update \
    --quiet \
    --manifest-path "$REPO_DIR/services/kittylitter/Cargo.toml" \
    -p alleycat \
    --precise "$ALLEYCAT_MAIN_SHA"
}

case "$MODE" in
  all)
    update_shared
    update_kittylitter
    ;;
  shared)
    update_shared
    ;;
  kittylitter)
    update_kittylitter
    ;;
esac
