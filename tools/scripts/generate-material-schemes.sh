#!/usr/bin/env bash
# Generate LitterMaterialSchemes.generated.kt from the shared theme JSONs using
# the official Material color-utilities. Safe to run from anywhere; resolves
# the repo root from the script location.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLS_SCRIPTS="$REPO_ROOT/tools/scripts"

DEPS_STAMP="$TOOLS_SCRIPTS/node_modules/.material-schemes-lock"
if [[ ! -f "$DEPS_STAMP" ]] || \
   ! cmp -s "$TOOLS_SCRIPTS/package-lock.json" "$DEPS_STAMP" || \
   [[ "$TOOLS_SCRIPTS/package.json" -nt "$DEPS_STAMP" ]] || \
   [[ ! -d "$TOOLS_SCRIPTS/node_modules/@material/material-color-utilities" ]]; then
  echo "==> Installing material-color-utilities tool deps..."
  npm ci --prefix "$TOOLS_SCRIPTS" --no-audit --no-fund
  cp "$TOOLS_SCRIPTS/package-lock.json" "$DEPS_STAMP"
fi

node --import "$TOOLS_SCRIPTS/register-esm.mjs" \
  "$TOOLS_SCRIPTS/generate-material-schemes.mjs"
