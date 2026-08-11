#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GHOSTTY_DIR="$REPO_DIR/shared/third_party/ghostty"

required_version="$(
  sed -n -E 's/^[[:space:]]*\.?minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$GHOSTTY_DIR/build.zig.zon" | head -n 1
)"
if [ -z "$required_version" ]; then
  echo "error: could not read Ghostty's required Zig version" >&2
  exit 1
fi

matches_required_version() {
  local candidate="$1"
  [ -x "$candidate" ] && [ "$("$candidate" version 2>/dev/null)" = "$required_version" ]
}

if [ -n "${GHOSTTY_ZIG_BIN:-}" ]; then
  if ! matches_required_version "$GHOSTTY_ZIG_BIN"; then
    echo "error: GHOSTTY_ZIG_BIN must point to Zig $required_version: $GHOSTTY_ZIG_BIN" >&2
    exit 1
  fi
  printf '%s\n' "$GHOSTTY_ZIG_BIN"
  exit 0
fi

path_candidate="$(command -v zig 2>/dev/null || true)"
brew_candidate=""
if command -v brew >/dev/null 2>&1; then
  brew_formula="zig@${required_version%.*}"
  brew_prefix="$(brew --prefix "$brew_formula" 2>/dev/null || true)"
  if [ -n "$brew_prefix" ]; then
    brew_candidate="$brew_prefix/bin/zig"
  fi
fi

for candidate in \
  "$path_candidate" \
  "$brew_candidate" \
  /opt/homebrew/bin/zig \
  /usr/local/bin/zig
do
  if matches_required_version "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

echo "error: Ghostty requires Zig $required_version; install zig@${required_version%.*} or set GHOSTTY_ZIG_BIN" >&2
exit 1
