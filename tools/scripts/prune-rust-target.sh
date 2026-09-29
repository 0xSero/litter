#!/usr/bin/env bash
# Keep the shared Cargo target under a size cap. Cargo never garbage-collects
# incremental session dirs or stale dependency builds, so without this the
# target grows by tens of GB per week of normal iteration.
#
# Stages, stopping as soon as the target fits under the cap:
#   1. delete every `incremental/` cache (rebuilt on the next build)
#   2. delete the host `debug/` profile (cargo check/test, rust-analyzer)
#   3. delete the target's contents (next build is a full rebuild)
#
# Safety: only acts on a directory Cargo created (named `target`, holding
# Cargo's CACHEDIR.TAG), never on `/` or $HOME, and does nothing while any
# cargo/rustc process is running, since worktrees share this target.
#
# Usage: prune-rust-target.sh <target-dir>
# Env:   LITTER_RUST_TARGET_MAX_GB (default 60; 0 disables pruning)
set -euo pipefail

target="${1:?usage: prune-rust-target.sh <target-dir>}"
max_gb="${LITTER_RUST_TARGET_MAX_GB:-60}"

case "$max_gb" in
    '' | *[!0-9]*)
        echo "==> prune-rust-target: LITTER_RUST_TARGET_MAX_GB must be a whole number, got '$max_gb'; not pruning" >&2
        exit 0
        ;;
esac
[ "$max_gb" -eq 0 ] && exit 0
[ -d "$target" ] || exit 0

target="$(cd "$target" && pwd -P)"
if [ "$target" = "/" ] || [ "$target" = "$(cd "$HOME" && pwd -P)" ] \
    || [ "$(basename "$target")" != "target" ] \
    || ! grep -qs "Signature: 8a477f597d28d172789f06886806bc55" "$target/CACHEDIR.TAG"; then
    echo "==> prune-rust-target: $target is not a Cargo target directory; not pruning" >&2
    exit 0
fi

if pgrep -x cargo >/dev/null 2>&1 || pgrep -x rustc >/dev/null 2>&1; then
    echo "==> prune-rust-target: a cargo/rustc process is running; skipping this time" >&2
    exit 0
fi

size_gb() { du -sk "$target" 2>/dev/null | awk '{print int($1 / 1048576)}'; }

size="$(size_gb)"
[ "$size" -le "$max_gb" ] && exit 0
echo "==> Rust target is ${size}GB (cap ${max_gb}GB); pruning $target"

find "$target" -maxdepth 3 -type d -name incremental -prune -exec rm -rf {} +
size="$(size_gb)"
echo "    after dropping incremental caches: ${size}GB"
[ "$size" -le "$max_gb" ] && exit 0

rm -rf "$target/debug"
size="$(size_gb)"
echo "    after dropping host debug profile: ${size}GB"
[ "$size" -le "$max_gb" ] && exit 0

echo "    still over cap; clearing the target (next build is a full rebuild)"
find "$target" -mindepth 1 -maxdepth 1 ! -name CACHEDIR.TAG -exec rm -rf {} +
