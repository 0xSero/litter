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

alleycat_branch() {
  local manifest="$1"
  sed -nE 's/.*dnakov\/alleycat\.git.*branch = "([^"]+)".*/\1/p' "$manifest" | head -1
}

SHARED_ALLEYCAT_BRANCH="$(alleycat_branch "$REPO_DIR/shared/rust-bridge/Cargo.toml")"
KITTYLITTER_ALLEYCAT_BRANCH="$(alleycat_branch "$REPO_DIR/services/kittylitter/Cargo.toml")"

resolve_alleycat_sha() {
  local branch="$1"
  git ls-remote https://github.com/dnakov/alleycat.git "refs/heads/$branch" \
    | awk '{ print $1; exit }'
}

update_shared() {
  local sha
  sha="$(resolve_alleycat_sha "$SHARED_ALLEYCAT_BRANCH")"
  if [ -z "$sha" ]; then
    echo "error: could not resolve dnakov/alleycat $SHARED_ALLEYCAT_BRANCH" >&2
    exit 1
  fi
  echo "==> Resolving shared Rust Alleycat deps to dnakov/alleycat $SHARED_ALLEYCAT_BRANCH ($sha)..."
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
      --precise "$sha"
  done
}

update_kittylitter() {
  local sha
  sha="$(resolve_alleycat_sha "$KITTYLITTER_ALLEYCAT_BRANCH")"
  if [ -z "$sha" ]; then
    echo "error: could not resolve dnakov/alleycat $KITTYLITTER_ALLEYCAT_BRANCH" >&2
    exit 1
  fi
  echo "==> Resolving kittylitter Alleycat dep to dnakov/alleycat $KITTYLITTER_ALLEYCAT_BRANCH ($sha)..."
  cargo update \
    --quiet \
    --manifest-path "$REPO_DIR/services/kittylitter/Cargo.toml" \
    -p alleycat \
    --precise "$sha"
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
