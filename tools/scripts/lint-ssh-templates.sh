#!/usr/bin/env bash
set -euo pipefail

script_dir="${1:?usage: lint-ssh-templates.sh <script-dir>}"
rendered_dir="$(mktemp -d)"
trap 'rm -rf "$rendered_dir"' EXIT

for source_path in "$script_dir"/*.sh; do
    sed \
        -e 's|{{PROFILE_INIT}}|:|g' \
        -e 's|{{PORT}}|45000|g' \
        -e 's|{{BIN}}|/usr/bin/true|g' \
        -e 's|{{COMMAND}}|true|g' \
        -e 's|{{SESSION_ID}}|litter-test|g' \
        -e 's|{{ROOT}}|/tmp/litter-test|g' \
        -e 's|{{INPUT}}|/tmp/litter-test/input|g' \
        -e 's|{{OUT_LOG}}|/tmp/litter-test/out.log|g' \
        -e 's|{{ERR_LOG}}|/tmp/litter-test/err.log|g' \
        -e 's|{{AGENT_PID}}|/tmp/litter-test/agent.pid|g' \
        -e 's|{{KEEPER_PID}}|/tmp/litter-test/keeper.pid|g' \
        "$source_path" > "$rendered_dir/$(basename "$source_path")"
done

if grep -REn '\{\{[A-Z0-9_]+\}\}' "$rendered_dir"; then
    echo "error: unrendered SSH script placeholder" >&2
    exit 1
fi

echo "==> bash -n on rendered $script_dir/*.sh"
for rendered_path in "$rendered_dir"/*.sh; do
    bash -n "$rendered_path"
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "==> shellcheck rendered $script_dir/*.sh"
    shellcheck --shell=sh --severity=warning --exclude=SC1090 "$rendered_dir"/*.sh
else
    echo "==> shellcheck not installed, skipping (brew install shellcheck)"
fi
