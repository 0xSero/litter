#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FINALIZE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/testflight-finalize.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/testflight-finalize.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/asc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_ASC_LOG"

case "$1:$2:${3:-}" in
    builds:list:--app)
        printf '%s\n' '{"data":[{"id":"build-1","attributes":{"version":"200000258"}}]}'
        ;;
    testflight:app-localizations:list)
        if [[ "${MOCK_LOCALIZATION_EXISTS:-0}" == "1" ]]; then
            printf '%s\n' '{"data":[{"id":"localization-1","attributes":{"locale":"en-US"}}]}'
        else
            printf '%s\n' '{"data":[]}'
        fi
        ;;
    testflight:app-localizations:create|testflight:app-localizations:update)
        printf '%s\n' '{"data":{"id":"localization-1"}}'
        ;;
    testflight:review:view)
        if [[ "${MOCK_BETA_CONTACT_EXISTS:-0}" == "1" ]]; then
            printf '%s\n' '{"data":{"id":"beta-review-1","attributes":{"contactFirstName":"Beta","contactLastName":"Tester","contactEmail":"beta@example.com","contactPhone":"+15555550100"}}}'
        else
            printf '%s\n' '{"data":{"id":"beta-review-1","attributes":{}}}'
        fi
        ;;
    testflight:review:edit)
        printf '%s\n' '{"data":{"id":"beta-review-1"}}'
        ;;
    versions:list:--app)
        printf '%s\n' '{"data":[{"id":"version-1"}]}'
        ;;
    review:details-for-version:--version-id)
        if [[ "${MOCK_APP_STORE_CONTACT_EXISTS:-0}" == "1" ]]; then
            printf '%s\n' '{"data":{"id":"app-review-1","attributes":{"contactFirstName":"App","contactLastName":"Reviewer","contactEmail":"review@example.com","contactPhone":"+15555550101"}}}'
        else
            printf '%s\n' '{"data":{"id":"app-review-1","attributes":{}}}'
        fi
        ;;
    builds:test-notes:update)
        if [[ "${MOCK_NOTE_UPDATE_FAILS:-0}" == "1" ]]; then
            exit 1
        fi
        printf '%s\n' '{"data":{"id":"note-1"}}'
        ;;
    builds:test-notes:create)
        printf '%s\n' '{"data":{"id":"note-1"}}'
        ;;
    testflight:groups:list)
        printf '%s\n' '{"data":[{"id":"internal-1","attributes":{"name":"Internal Testers"}},{"id":"external-1","attributes":{"name":"Beta Testers"}}]}'
        ;;
    builds:add-groups:--build-id)
        printf '%s\n' '{"data":[]}'
        ;;
    validate:testflight:--app)
        printf '%s\n' '{"valid":true}'
        ;;
    testflight:review:submissions)
        if [[ "${MOCK_SUBMISSION_EXISTS:-0}" == "1" ]]; then
            printf '%s\n' '{"data":[{"id":"submission-1"}]}'
        else
            printf '%s\n' '{"data":[]}'
        fi
        ;;
    testflight:review:submit)
        printf '%s\n' '{"data":{"id":"submission-1"}}'
        ;;
    *)
        echo "Unexpected asc invocation: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/asc"

printf '%s\n' 'A durable beta description.' > "$TEST_ROOT/beta-description.txt"
printf '%s\n' 'Exercise pairing, streaming, reasoning, and tool calls.' > "$TEST_ROOT/whats-new.md"

run_finalize() {
    PATH="$TEST_ROOT/bin:$PATH" \
    APP_STORE_APP_ID="123456789" \
    MARKETING_VERSION="1.7.0" \
    BUILD_NUMBER="200000258" \
    BETA_GROUP_NAMES="Internal Testers,Beta Testers" \
    BETA_APP_DESCRIPTION_FILE="$TEST_ROOT/beta-description.txt" \
    WHAT_TO_TEST_FILE="$TEST_ROOT/whats-new.md" \
    BUILD_POLL_INTERVAL_SECONDS="0" \
    BUILD_POLL_TIMEOUT_SECONDS="5" \
    MOCK_ASC_LOG="$MOCK_ASC_LOG" \
    MOCK_LOCALIZATION_EXISTS="${MOCK_LOCALIZATION_EXISTS:-0}" \
    MOCK_NOTE_UPDATE_FAILS="${MOCK_NOTE_UPDATE_FAILS:-0}" \
    MOCK_SUBMISSION_EXISTS="${MOCK_SUBMISSION_EXISTS:-0}" \
    MOCK_BETA_CONTACT_EXISTS="${MOCK_BETA_CONTACT_EXISTS:-0}" \
    MOCK_APP_STORE_CONTACT_EXISTS="${MOCK_APP_STORE_CONTACT_EXISTS:-0}" \
    ASSIGN_BETA_GROUP="${ASSIGN_BETA_GROUP:-1}" \
    "$FINALIZE_SCRIPT"
}

MOCK_ASC_LOG="$TEST_ROOT/create.log"
MOCK_LOCALIZATION_EXISTS=0
MOCK_NOTE_UPDATE_FAILS=1
MOCK_SUBMISSION_EXISTS=0
MOCK_BETA_CONTACT_EXISTS=0
MOCK_APP_STORE_CONTACT_EXISTS=1
ASSIGN_BETA_GROUP=1
run_finalize
grep -q 'testflight app-localizations create' "$MOCK_ASC_LOG"
grep -q 'versions list' "$MOCK_ASC_LOG"
grep -q 'review details-for-version' "$MOCK_ASC_LOG"
grep -q 'testflight review edit' "$MOCK_ASC_LOG"
grep -q -- '--demo-account-required=false' "$MOCK_ASC_LOG"
grep -q -- '--notes A durable beta description.' "$MOCK_ASC_LOG"
grep -q 'builds test-notes create' "$MOCK_ASC_LOG"
grep -q 'testflight review submit' "$MOCK_ASC_LOG"
grep -q 'validate testflight' "$MOCK_ASC_LOG"

MOCK_ASC_LOG="$TEST_ROOT/update.log"
MOCK_LOCALIZATION_EXISTS=1
MOCK_NOTE_UPDATE_FAILS=0
MOCK_SUBMISSION_EXISTS=1
MOCK_BETA_CONTACT_EXISTS=1
MOCK_APP_STORE_CONTACT_EXISTS=0
run_finalize
grep -q 'testflight app-localizations update' "$MOCK_ASC_LOG"
grep -q 'testflight review edit' "$MOCK_ASC_LOG"
if grep -q 'versions list' "$MOCK_ASC_LOG"; then
    echo "Existing TestFlight review contact unexpectedly queried App Store versions." >&2
    exit 1
fi
grep -q 'builds test-notes update' "$MOCK_ASC_LOG"
if grep -q 'testflight review submit' "$MOCK_ASC_LOG"; then
    echo "Existing Beta App Review submission was submitted twice." >&2
    exit 1
fi

MOCK_ASC_LOG="$TEST_ROOT/metadata-only.log"
MOCK_LOCALIZATION_EXISTS=1
MOCK_NOTE_UPDATE_FAILS=0
MOCK_SUBMISSION_EXISTS=0
MOCK_BETA_CONTACT_EXISTS=1
MOCK_APP_STORE_CONTACT_EXISTS=0
ASSIGN_BETA_GROUP=0
run_finalize
grep -q 'testflight app-localizations update' "$MOCK_ASC_LOG"
grep -q 'builds test-notes update' "$MOCK_ASC_LOG"
grep -q 'validate testflight' "$MOCK_ASC_LOG"
if grep -Eq 'testflight groups|builds add-groups|testflight review (submissions|submit)' "$MOCK_ASC_LOG"; then
    echo "Metadata-only finalization changed TestFlight groups or review state." >&2
    exit 1
fi

MOCK_ASC_LOG="$TEST_ROOT/missing-contact.log"
MOCK_BETA_CONTACT_EXISTS=0
MOCK_APP_STORE_CONTACT_EXISTS=0
if run_finalize >"$TEST_ROOT/missing-contact.out" 2>&1; then
    echo "Finalization succeeded without Beta App Review contact details." >&2
    exit 1
fi
grep -q 'Populate REVIEW_CONTACT_FIRST_NAME' "$TEST_ROOT/missing-contact.out"
if grep -q 'testflight review edit' "$MOCK_ASC_LOG"; then
    echo "Incomplete Beta App Review contact details were written." >&2
    exit 1
fi

echo "testflight-finalize tests passed"
