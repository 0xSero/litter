#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/app-store-release.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
export MOCK_ASC_LOG="$TEST_ROOT/asc.log"
export MOCK_VERSION_CREATED="$TEST_ROOT/version-created"
mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/asc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_ASC_LOG"
case "$1:$2" in
    migrate:validate) echo '{}' ;;
    builds:list) echo '{"data":[{"id":"build-1","attributes":{"version":"265"}}]}' ;;
    versions:list)
        if [[ -f "$MOCK_VERSION_CREATED" ]]; then
            echo '{"data":[{"id":"version-1"}]}'
        else
            echo '{"data":[]}'
        fi ;;
    versions:create)
        touch "$MOCK_VERSION_CREATED"
        # asc 5.3 returns a flattened version detail result.
        echo '{"id":"version-1","versionString":"2.1.1"}' ;;
    versions:update) echo '{}' ;;
    migrate:import)
        [[ " $* " == *" --confirm "* ]]
        if [[ "${MOCK_IMPORT_FAIL:-0}" == 1 ]]; then exit 1; fi
        echo '{}' ;;
    versions:attach-build)
        [[ " $* " == *" --build-id build-1 "* ]]
        [[ " $* " != *" --build "* ]]
        echo '{}' ;;
    age-rating:edit|validate:--app) echo '{}' ;;
    review:submissions-create) echo '{"data":{"id":"submission-1"}}' ;;
    review:items-add|review:submissions-submit)
        [[ " $* " == *" submission-1 "* ]]
        echo '{}' ;;
    *) echo "Unexpected asc invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/asc"

run_release() {
    PATH="$TEST_ROOT/bin:$PATH" \
    APP_STORE_APP_ID=123456789 MARKETING_VERSION=2.1.1 BUILD_NUMBER=265 \
    BUILD_DIR="$TEST_ROOT/build" \
    bash "$SCRIPT_DIR/../app-store-release.sh"
}

run_release
grep -q 'review submissions-submit' "$MOCK_ASC_LOG"
grep -q 'versions attach-build --version-id version-1 --build-id build-1' "$MOCK_ASC_LOG"

: > "$MOCK_ASC_LOG"
export MOCK_IMPORT_FAIL=1
if run_release >"$TEST_ROOT/import-failure.log" 2>&1; then
    echo 'Release unexpectedly continued after metadata import failed.' >&2
    exit 1
fi
if grep -Eq 'versions attach-build|review submissions' "$MOCK_ASC_LOG"; then
    echo 'Release changed the selected build or review after metadata import failed.' >&2
    exit 1
fi
echo 'app-store-release tests passed'
