#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ANDROID_DIR="$REPO_DIR/apps/android"
GRADLEW="$ANDROID_DIR/gradlew"

VARIANT="${VARIANT:-Release}"
UPLOAD="${UPLOAD:-1}"
TRACK="${LITTER_PLAY_TRACK:-internal}"
# Comma-separated list of tracks to promote the uploaded artifact to.
# Each listed track gets its own `promoteReleaseArtifact` invocation with
# the source `TRACK` as the origin. Empty = upload only, no promotion.
PROMOTE_TRACK="${LITTER_PLAY_PROMOTE_TRACK:-}"
# Release status applied to the final landing track. A build-only upload
# defaults to DRAFT; promotion requires a completed source release.
RELEASE_STATUS="${LITTER_PLAY_RELEASE_STATUS:-draft}"
USER_FRACTION="${LITTER_PLAY_USER_FRACTION:-}"
GRADLE_MAX_WORKERS="${GRADLE_MAX_WORKERS:-}"
EXTRA_GRADLE_TASKS="${EXTRA_GRADLE_TASKS:-}"
GRADLE_EXCLUDED_TASKS="${GRADLE_EXCLUDED_TASKS:-}"

declare -a GRADLE_ARGS=(--no-daemon)
if [[ -n "$GRADLE_MAX_WORKERS" ]]; then
    GRADLE_ARGS+=("--max-workers=$GRADLE_MAX_WORKERS")
fi
if [[ -n "$GRADLE_EXCLUDED_TASKS" ]]; then
    EXCLUDED_TASKS_NORMALIZED="${GRADLE_EXCLUDED_TASKS//,/ }"
    read -r -a EXCLUDED_TASKS <<<"$EXCLUDED_TASKS_NORMALIZED"
    for task in "${EXCLUDED_TASKS[@]}"; do
        [[ -n "$task" ]] || continue
        GRADLE_ARGS+=("-x" "$task")
    done
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/litter"
for ENV_FILE in "$CONFIG_DIR/play-upload.env" "$CONFIG_DIR/upload-signing.env"; do
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
    fi
done

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required env var: $name" >&2
        echo "Hint: create $ENV_FILE with exports, or set vars directly." >&2
        exit 1
    fi
}

# Shared signing + service-account props used by every Gradle invocation.
# Note: -PLITTER_PLAY_PROMOTE_TRACK is NOT set here; it's added per-promote
# below because we may fan out to multiple destination tracks.
declare -a BASE_PROPS=(
    -PLITTER_PLAY_SERVICE_ACCOUNT_JSON="${LITTER_PLAY_SERVICE_ACCOUNT_JSON:-}"
    -PLITTER_PLAY_TRACK="$TRACK"
    -PLITTER_UPLOAD_STORE_FILE="${LITTER_UPLOAD_STORE_FILE:-}"
    -PLITTER_UPLOAD_STORE_PASSWORD="${LITTER_UPLOAD_STORE_PASSWORD:-}"
    -PLITTER_UPLOAD_KEY_ALIAS="${LITTER_UPLOAD_KEY_ALIAS:-}"
    -PLITTER_UPLOAD_KEY_PASSWORD="${LITTER_UPLOAD_KEY_PASSWORD:-}"
)

# ── Local build only ───────────────────────────────────────────────────────
if [[ "$UPLOAD" != "1" ]]; then
    TASK=":app:bundle${VARIANT}"
    echo "==> Building local AAB for $VARIANT (no upload)"
    GRADLE_TASKS=()
    if [[ -n "$EXTRA_GRADLE_TASKS" ]]; then
        EXTRA_TASKS_NORMALIZED="${EXTRA_GRADLE_TASKS//,/ }"
        read -r -a EXTRA_TASKS <<<"$EXTRA_TASKS_NORMALIZED"
        GRADLE_TASKS+=("${EXTRA_TASKS[@]}")
    fi
    GRADLE_TASKS+=("$TASK")
    "$GRADLEW" -p "$ANDROID_DIR" "${GRADLE_ARGS[@]}" "${GRADLE_TASKS[@]}"
    echo "==> Done"
    exit 0
fi

require_env "LITTER_PLAY_SERVICE_ACCOUNT_JSON"
require_env "LITTER_UPLOAD_STORE_FILE"
require_env "LITTER_UPLOAD_STORE_PASSWORD"
require_env "LITTER_UPLOAD_KEY_ALIAS"
require_env "LITTER_UPLOAD_KEY_PASSWORD"

if [[ ! -f "$LITTER_PLAY_SERVICE_ACCOUNT_JSON" ]]; then
    echo "Service account JSON not found: $LITTER_PLAY_SERVICE_ACCOUNT_JSON" >&2
    exit 1
fi
if [[ ! -f "$LITTER_UPLOAD_STORE_FILE" ]]; then
    echo "Upload keystore not found: $LITTER_UPLOAD_STORE_FILE" >&2
    exit 1
fi

# ── Step 1: publish to the source track ─────────────────────────────────────
# Promotion requires a completed source release. Upload-only runs respect the
# requested status and default to DRAFT so preparing an artifact cannot
# accidentally make it visible to testers.
PUBLISH_TASK=":app:publish${VARIANT}Bundle"
status_for_upload="$RELEASE_STATUS"
if [[ -n "$PROMOTE_TRACK" ]]; then
    status_for_upload="completed"
fi
echo "==> Publishing $VARIANT bundle to Google Play track '$TRACK' [status=$status_for_upload]"

declare -a PUBLISH_TASKS=()
if [[ -n "$EXTRA_GRADLE_TASKS" ]]; then
    EXTRA_TASKS_NORMALIZED="${EXTRA_GRADLE_TASKS//,/ }"
    read -r -a EXTRA_TASKS <<<"$EXTRA_TASKS_NORMALIZED"
    PUBLISH_TASKS+=("${EXTRA_TASKS[@]}")
fi
PUBLISH_TASKS+=("$PUBLISH_TASK")

"$GRADLEW" -p "$ANDROID_DIR" "${GRADLE_ARGS[@]}" "${PUBLISH_TASKS[@]}" "${BASE_PROPS[@]}" \
    -PLITTER_PLAY_RELEASE_STATUS="$status_for_upload"

# ── Step 2: optionally promote to one or more tracks ───────────────────────
# Each destination is an independent Play release, so fan out.
if [[ -n "$PROMOTE_TRACK" ]]; then
    PROMOTE_TASK=":app:promote${VARIANT}Artifact"
    status_for_promote="$RELEASE_STATUS"
    rollout_info=""
    if [[ "$status_for_promote" == "inProgress" || "$status_for_promote" == "in_progress" ]]; then
        rollout_info=" (staged at userFraction=${USER_FRACTION:-not set})"
    fi

    IFS=',' read -r -a DESTS <<<"$PROMOTE_TRACK"
    for dest in "${DESTS[@]}"; do
        dest_trimmed="${dest// /}"
        [[ -n "$dest_trimmed" ]] || continue
        declare -a PROMOTE_PROPS=(
            -PLITTER_PLAY_PROMOTE_TRACK="$dest_trimmed"
            -PLITTER_PLAY_RELEASE_STATUS="$status_for_promote"
        )
        if [[ -n "$USER_FRACTION" ]]; then
            PROMOTE_PROPS+=(-PLITTER_PLAY_USER_FRACTION="$USER_FRACTION")
        fi
        echo "==> Promoting '$TRACK' → '$dest_trimmed' [status=$status_for_promote]${rollout_info}"
        "$GRADLEW" -p "$ANDROID_DIR" "${GRADLE_ARGS[@]}" "$PROMOTE_TASK" "${BASE_PROPS[@]}" "${PROMOTE_PROPS[@]}"
    done
fi

echo "==> Done"
