#!/usr/bin/env bash
set -euo pipefail

# Watch iOS+Rust sources and rebuild on save. Splits dispatch so Swift-only
# edits skip the Rust pipeline entirely. Pass `sim` or `device` as the first
# arg (default: sim). Add `-run` (e.g. `sim-run`) to also install+launch on
# each rebuild — be aware that relaunches the app every save.

MODE="${1:-sim}"
case "$MODE" in
  sim)        BUILD_TARGET=ios-build-sim-fast    ; SWIFT_TARGET=ios-xcode-sim-fast    ; RUN_TARGET="" ;;
  sim-run)    BUILD_TARGET=ios-build-sim-fast    ; SWIFT_TARGET=ios-xcode-sim-fast    ; RUN_TARGET=ios-sim-launch ;;
  device)     BUILD_TARGET=ios-build-device-fast ; SWIFT_TARGET=ios-xcode-device-fast ; RUN_TARGET="" ;;
  device-run) BUILD_TARGET=ios-build-device-fast ; SWIFT_TARGET=ios-xcode-device-fast ; RUN_TARGET=ios-device-launch ;;
  *)
    echo "usage: $0 [sim|sim-run|device|device-run]" >&2
    exit 1
    ;;
esac

if ! command -v fswatch >/dev/null 2>&1; then
  echo "ERROR: fswatch not installed. Run: brew install fswatch" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK="/tmp/litter-loop-ios.lock"

WATCH_DIRS=(
  "$ROOT/shared/rust-bridge/codex-mobile-client"
  "$ROOT/apps/ios/Sources"
  "$ROOT/apps/ios/Resources"
  "$ROOT/apps/ios/project.yml"
)

run_target() {
  local target="$1"
  local label="$2"
  (
    flock -n 9 || { echo "[loop] build in progress — skipping ($label)"; exit 0; }
    echo
    echo "==> [loop] $(date +%H:%M:%S) $label → make $target"
    cd "$ROOT" && make "$target"
    if [ -n "$RUN_TARGET" ]; then
      echo "==> [loop] $(date +%H:%M:%S) launching → make $RUN_TARGET"
      cd "$ROOT" && make "$RUN_TARGET"
    fi
    echo "==> [loop] $(date +%H:%M:%S) done"
  ) 9>"$LOCK"
}

echo "==> [loop] watching for changes (MODE=$MODE)"
echo "    rust changes → make $BUILD_TARGET"
echo "    swift changes → make $SWIFT_TARGET (Rust skipped)"
[ -n "$RUN_TARGET" ] && echo "    after each build → make $RUN_TARGET"
echo "    Ctrl+C to stop"

# -0 NUL-separated output; -r recursive; --latency 1 debounces bursts.
# Excludes keep build artifacts and VCS noise from triggering rebuilds.
fswatch -0 -r --latency 1 \
  --exclude '/\.git/' \
  --exclude '/target/' \
  --exclude '/\.build/' \
  --exclude '/\.build-stamps/' \
  --exclude '/DerivedData/' \
  --exclude '/GeneratedRust/' \
  --exclude '/Frameworks/' \
  --exclude '\.generated\.(swift|rs|kt|h)$' \
  --exclude '/generated/' \
  "${WATCH_DIRS[@]}" \
| while IFS= read -r -d '' path; do
    case "$path" in
      *.rs|*/Cargo.toml|*/Cargo.lock)
        run_target "$BUILD_TARGET" "rust+swift ($(basename "$path"))"
        ;;
      */project.yml)
        (
          flock -n 9 || { echo "[loop] build in progress — skipping (project.yml)"; exit 0; }
          echo
          echo "==> [loop] $(date +%H:%M:%S) project.yml → make xcgen + $SWIFT_TARGET"
          cd "$ROOT" && make xcgen && make "$SWIFT_TARGET"
          if [ -n "$RUN_TARGET" ]; then
            cd "$ROOT" && make "$RUN_TARGET"
          fi
        ) 9>"$LOCK"
        ;;
      *.swift|*.yml|*.plist|*.xcassets/*|*.storyboard|*.xib)
        run_target "$SWIFT_TARGET" "swift ($(basename "$path"))"
        ;;
      *)
        # Ignore other change types (editor swap files, etc.)
        ;;
    esac
  done
