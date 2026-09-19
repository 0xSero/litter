#!/usr/bin/env bash
set -euo pipefail

# Apply Litter's local patches to the vendored Ghostty submodule.
#
# Pattern mirrors apps/ios/scripts/sync-codex.sh. Patches live under
# patches/ghostty/*.patch and add mobile-embed capability that upstream
# Ghostty does not yet ship:
#   - GHOSTTY_PLATFORM_ANDROID with EGL native_window plumbing
#   - external_pty mode: host owns the byte stream, Ghostty just renders
#
# This script is idempotent: it detects already-applied patches and exits
# cleanly. Safe to call from build-ghostty.sh on every build.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
SUBMODULE_DIR="$REPO_DIR/shared/third_party/ghostty"
PATCH_DIR="$REPO_DIR/patches/ghostty"

PATCH_FILES=(
    "$PATCH_DIR/litter-mobile-embed.patch"
    "$PATCH_DIR/android-epoll.patch"
)

SYNC_MODE="${1:---preserve-current}"
case "$SYNC_MODE" in
    --preserve-current|--recorded-gitlink)
        ;;
    *)
        echo "usage: $(basename "$0") [--preserve-current|--recorded-gitlink]" >&2
        exit 1
        ;;
esac

if [ ! -d "$SUBMODULE_DIR/.git" ] && [ ! -f "$SUBMODULE_DIR/.git" ]; then
    echo "==> ghostty submodule missing; initializing..."
    git -C "$REPO_DIR" submodule update --init --recursive shared/third_party/ghostty
fi

if ! git -C "$SUBMODULE_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$REPO_DIR" submodule update --init --recursive shared/third_party/ghostty
elif [ "$SYNC_MODE" = "--recorded-gitlink" ]; then
    git -C "$REPO_DIR" submodule update --init --recursive shared/third_party/ghostty
else
    recorded_commit="$(git -C "$REPO_DIR" ls-files --stage shared/third_party/ghostty | awk 'NR == 1 { print $2 }')"
    current_commit="$(git -C "$SUBMODULE_DIR" rev-parse HEAD)"
    if [ -z "$recorded_commit" ]; then
        echo "error: could not resolve recorded submodule gitlink for shared/third_party/ghostty" >&2
        exit 1
    fi
    if [ "$current_commit" = "$recorded_commit" ]; then
        echo "==> ghostty submodule already at recorded gitlink ${current_commit:0:9}"
    else
        echo "==> Preserving current ghostty checkout ${current_commit:0:9} (recorded gitlink ${recorded_commit:0:9})"
    fi
fi

for PATCH_FILE in "${PATCH_FILES[@]}"; do
    PATCH_NAME="$(basename "$PATCH_FILE")"
    if [ ! -f "$PATCH_FILE" ]; then
        echo "error: missing patch file: $PATCH_FILE" >&2
        exit 1
    fi

    if git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
        echo "==> $PATCH_NAME already applied."
    elif git -C "$SUBMODULE_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
        echo "==> Applying $PATCH_NAME to submodule..."
        git -C "$SUBMODULE_DIR" apply "$PATCH_FILE"
    else
        # Content-presence fallback when --reverse --check fails (e.g. multiple
        # patches touching the same files, or partial apply).
        patch_targets=()
        while IFS= read -r pf; do
            [ -f "$SUBMODULE_DIR/$pf" ] && patch_targets+=("$SUBMODULE_DIR/$pf")
        done < <({ grep '^diff --git' "$PATCH_FILE" | sed 's|.*b/||'; \
                    grep '^--- a/' "$PATCH_FILE" | sed 's|^--- a/||'; } | sort -u)
        added_lines=$(grep -m 5 '^+[^+]' "$PATCH_FILE" | sed 's/^+//')
        all_present=true
        if [ "${#patch_targets[@]}" -eq 0 ]; then
            all_present=false
        else
            while IFS= read -r line; do
                trimmed="${line#"${line%%[![:space:]]*}"}"
                [ -z "$trimmed" ] && continue
                if ! grep -qF "$trimmed" "${patch_targets[@]}" 2>/dev/null; then
                    all_present=false
                    break
                fi
            done <<< "$added_lines"
        fi
        if [ "$all_present" = true ]; then
            echo "==> $PATCH_NAME already applied (content check)."
        else
            echo "error: $PATCH_NAME no longer applies cleanly to ghostty $(git -C "$SUBMODULE_DIR" rev-parse --short HEAD)" >&2
            echo "error: refresh $PATCH_FILE before rebuilding libghostty" >&2
            exit 1
        fi
    fi
done

echo "==> ghostty submodule ready at $(git -C "$SUBMODULE_DIR" rev-parse --short HEAD)"
