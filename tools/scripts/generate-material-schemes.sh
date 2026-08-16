#!/usr/bin/env bash
# Generate LitterMaterialSchemes.generated.kt from the shared theme JSONs using
# the official Material color-utilities. Safe to run from anywhere; resolves
# the repo root from the script location.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLS_SCRIPTS="$REPO_ROOT/tools/scripts"

if [[ ! -d "$TOOLS_SCRIPTS/node_modules/@material/material-color-utilities" ]]; then
  echo "==> Installing material-color-utilities tool deps..."
  npm install --prefix "$TOOLS_SCRIPTS" --no-audit --no-fund
fi

node --import "$TOOLS_SCRIPTS/register-esm.mjs" \
  "$TOOLS_SCRIPTS/generate-material-schemes.mjs"
