#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage:' \
        '  pi-mission.sh start <task-number> <worktree>' \
        '  pi-mission.sh repair <task-number> <worktree> <review-file>' \
        '  pi-mission.sh status <task-number> <worktree>'
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

normalize_task() {
    local raw="$1"
    [[ "$raw" =~ ^[0-9]{1,2}$ ]] || fail "task number must be between 00 and 15"
    local value=$((10#$raw))
    (( value >= 0 && value <= 15 )) || fail "task number must be between 00 and 15"
    printf '%02d' "$value"
}

resolve_context() {
    task_number="$(normalize_task "$1")"
    [[ -d "$2" ]] || fail "worktree does not exist: $2"
    worktree="$(cd "$2" && pwd -P)"
    task_file="$worktree/work/chat-performance/tasks/task-$task_number.md"
    [[ -f "$task_file" ]] || fail "task brief not found: $task_file"

    # The single-quoted expression is a literal sed program; no shell expansion is intended.
    # shellcheck disable=SC2016
    mission_name="$(sed -n 's/^`\(pi-chat-[^`]*\)`.*/\1/p' "$task_file" | head -n 1)"
    [[ -n "$mission_name" ]] || fail "Pi mission name not found in $task_file"

    expected_branch="codex/$mission_name"
    current_branch="$(git -C "$worktree" branch --show-current)"
    [[ "$current_branch" == "$expected_branch" ]] || {
        fail "mission $task_number requires branch $expected_branch, found ${current_branch:-detached HEAD}"
    }

    mission_dir="$worktree/.pi-missions/task-$task_number"
    session_file="$mission_dir/session-id"
    mkdir -p "$mission_dir"
}

run_pi_turn() {
    local log_file="$1"
    local prompt="$2"
    shift 2

    (
        cd "$worktree"
        PI_SKIP_VERSION_CHECK=1 pi \
            --mode json \
            --provider homelab \
            --model glm-5.2 \
            --thinking high \
            --tools read,bash,edit,write,grep,find,ls \
            -a \
            "$@" \
            "$prompt"
    ) | tee "$log_file"

    jq -e '
        select(.type == "message_start")
        | select(.message.role == "assistant")
        | select(.message.provider == "homelab" and .message.model == "glm-5.2")
    ' "$log_file" >/dev/null || fail "Pi event stream did not prove homelab/glm-5.2"
}

start_mission() {
    [[ ! -f "$session_file" ]] || fail "mission already has a session; use repair or status"
    [[ -z "$(git -C "$worktree" status --porcelain)" ]] || fail "mission worktree must be clean before start"

    local timestamp log_file prompt session_id
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    log_file="$mission_dir/turn-00-$timestamp.jsonl"
    prompt="$(cat <<EOF
You are the delegated Pi mission $mission_name for Litter chat performance Task $task_number.

Read, in order:
1. AGENTS.md
2. GOAL.md
3. work/chat-performance/scope.md
4. work/chat-performance/rules.md
5. work/chat-performance/tasks/task-$task_number.md

Execute only that brief in the current dedicated worktree and branch. Investigate before changing code. Respect Rust-first ownership and mobile parity. Preserve unrelated work and submodules. Do not push, open or merge a PR, publish, release, alter authentication, or touch another worktree. Make small local commits only after their scoped validation passes.

Finish with exactly these labeled sections:
MISSION_STATUS=READY_FOR_REVIEW or MISSION_STATUS=BLOCKED
MODEL_PROOF=homelab/glm-5.2
BASE_AND_HEAD
CHANGES
EVIDENCE
VALIDATION
ACCEPTANCE
RISKS
QUESTIONS_FOR_CODEX
NEXT_MESSAGE_FOR_CODEX

READY_FOR_REVIEW is a request for independent Codex review, not self-approval. Be explicit about commands not run and acceptance surfaces not proven.
EOF
)"

    run_pi_turn "$log_file" "$prompt" --name "$mission_name"
    session_id="$(jq -r 'select(.type == "session") | .id' "$log_file" | head -n 1)"
    [[ -n "$session_id" && "$session_id" != "null" ]] || fail "Pi session UUID missing from event stream"
    printf '%s\n' "$session_id" >"$session_file"
    printf 'mission=%s\nsession_id=%s\nlog=%s\n' "$mission_name" "$session_id" "$log_file"
}

repair_mission() {
    local review_file="$3"
    [[ -f "$session_file" ]] || fail "mission has no recorded session; use start"
    [[ -f "$review_file" ]] || fail "review file not found: $review_file"

    local session_id timestamp turn_index log_file review prompt
    session_id="$(<"$session_file")"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    turn_index="$(find "$mission_dir" -maxdepth 1 -name 'turn-*.jsonl' | wc -l | tr -d ' ')"
    printf -v turn_index '%02d' "$turn_index"
    log_file="$mission_dir/turn-$turn_index-$timestamp.jsonl"
    review="$(<"$review_file")"
    prompt="$(cat <<EOF
Codex reviewed delegated mission Task $task_number and returned CHANGES_REQUESTED.

Review findings:
$review

Fix every finding in this same mission and worktree. Re-read the task acceptance criteria, inspect the current diff and commits, rerun the required validation, and do not push or open a PR. If a finding is factually wrong, respond with concrete source or command evidence instead of silently ignoring it.

Finish again with the exact mission handoff sections from GOAL.md and set MISSION_STATUS only to READY_FOR_REVIEW or BLOCKED.
EOF
)"

    run_pi_turn "$log_file" "$prompt" --session "$session_id"
    printf 'mission=%s\nsession_id=%s\nlog=%s\n' "$mission_name" "$session_id" "$log_file"
}

show_status() {
    printf 'task=%s\nmission=%s\nbranch=%s\n' "$task_number" "$mission_name" "$current_branch"
    if [[ ! -f "$session_file" ]]; then
        printf '%s\n' 'session_id=NOT_STARTED'
        return
    fi

    local session_id latest_log
    session_id="$(<"$session_file")"
    latest_log="$(find "$mission_dir" -maxdepth 1 -name 'turn-*.jsonl' -print | sort | tail -n 1)"
    printf 'session_id=%s\nlatest_log=%s\n' "$session_id" "${latest_log:-none}"
    if [[ -n "$latest_log" ]]; then
        jq -r '
            select(.type == "turn_end")
            | .message.content[]?
            | select(.type == "text")
            | .text
        ' "$latest_log" | tail -n 80
    fi
}

require_command git
require_command jq
require_command pi

command_name="${1:-}"
case "$command_name" in
    start)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        resolve_context "$2" "$3"
        start_mission
        ;;
    repair)
        [[ $# -eq 4 ]] || { usage >&2; exit 2; }
        resolve_context "$2" "$3"
        repair_mission "$2" "$3" "$4"
        ;;
    status)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        resolve_context "$2" "$3"
        show_status
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
