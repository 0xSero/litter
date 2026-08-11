#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ANDROID_DIR="$REPO_DIR/apps/android"

WITH_RUST=0
NO_OPEN=0

usage() {
  cat <<'EOF'
Usage: ./apps/android/scripts/rebuild-and-reopen.sh [options]

Rebuild the Android debug app and reopen the project in Android Studio.

Options:
      --with-rust    Rebuild Android Rust JNI bridge libs first
      --no-open      Skip reopening Android Studio
  -h, --help         Show this help
EOF
}

while [ "${1:-}" != "" ]; do
  case "$1" in
    --with-rust)
      WITH_RUST=1
      shift
      ;;
    --no-open)
      NO_OPEN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$WITH_RUST" -eq 1 ]; then
  echo "==> Rebuilding Android Rust bridge JNI libs..."
  make -C "$REPO_DIR" rust-android
fi

echo "==> Rebuilding Android debug app..."
make -C "$REPO_DIR" android-debug

if [ "$NO_OPEN" -eq 1 ]; then
  echo "==> Build complete (skipped reopen)."
  exit 0
fi

echo "==> Reopening Android project..."

if command -v studio >/dev/null 2>&1; then
  studio "$ANDROID_DIR" >/dev/null 2>&1 &
  echo "==> Opened via 'studio' command."
  exit 0
fi

if command -v open >/dev/null 2>&1; then
  if open -a "Android Studio" "$ANDROID_DIR"; then
    echo "==> Opened via macOS 'open -a \"Android Studio\"'."
    exit 0
  fi
fi

echo "warning: unable to auto-open Android Studio. Open manually: $ANDROID_DIR" >&2
echo "==> Build complete."
