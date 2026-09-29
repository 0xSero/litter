#!/usr/bin/env bash
# Keep the shared Cargo target under a size cap. Cargo never garbage-collects
# incremental session dirs or stale dependency builds, so without this the
# target grows by tens of GB per week of normal iteration.
#
# Stages, stopping as soon as the target fits under the cap:
#   1. delete every `incremental/` cache (rebuilt on the next build)
#   2. delete the host `debug/` profile (cargo check/test, rust-analyzer)
#   3. delete the whole target (next build is a full rebuild)
#
# Usage: prune-rust-target.sh <target-dir>
# Env:   LITTER_RUST_TARGET_MAX_GB (default 60; 0 disables pruning)
set -euo pipefail

target="${1:?usage: prune-rust-target.sh <target-dir>}"
max_gb="${LITTER_RUST_TARGET_MAX_GB:-60}"

[ "$max_gb" = "0" ] && exit 0
[ -d "$target" ] || exit 0

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

echo "    still over cap; removing the whole target (next build is a full rebuild)"
rm -rf "$target"
