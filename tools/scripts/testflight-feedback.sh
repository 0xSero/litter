#!/usr/bin/env bash
set -euo pipefail

# Fetch TestFlight feedback for a specific app version (or all versions).
#
# Usage:
#   ./tools/scripts/testflight-feedback.sh [VERSION]
#   ./tools/scripts/testflight-feedback.sh 1.0.4
#   ./tools/scripts/testflight-feedback.sh          # all feedback
#
# Options (env vars):
#   BUNDLE_ID          — app bundle ID (default: com.sigkitten.litter)
#   ASC_BIN            — path to `asc` CLI binary
#   DOWNLOAD_SCREENSHOTS — set to 1 to download screenshots locally (default: 0)
#   OUTPUT_DIR         — where to save screenshots (default: /tmp/testflight-feedback)
#   OUTPUT_FORMAT      — json, markdown, or summary (default: summary)
#   SINCE              — optional ISO-8601 lower bound for createdDate filtering
#   UNTIL              — optional ISO-8601 upper bound for createdDate filtering

VERSION="${1:-}"
BUNDLE_ID="${BUNDLE_ID:-com.sigkitten.litter}"
DOWNLOAD_SCREENSHOTS="${DOWNLOAD_SCREENSHOTS:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/testflight-feedback}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-summary}"
SINCE="${SINCE:-}"
UNTIL="${UNTIL:-}"

# --- Resolve asc binary ---
resolve_asc() {
    if [[ -n "${ASC_BIN:-}" ]] && [[ -x "$ASC_BIN" ]]; then
        echo "$ASC_BIN"
        return
    fi
    # Check common locations
    local candidates=(
        "$(command -v asc 2>/dev/null || true)"
        "$HOME/Downloads/Bitrig.app/Contents/Resources/claude-agent/asc"
        "/Applications/Bitrig.app/Contents/Resources/claude-agent/asc"
        "$HOME/.local/bin/asc"
    )
    for c in "${candidates[@]}"; do
        if [[ -n "$c" ]] && [[ -x "$c" ]]; then
            echo "$c"
            return
        fi
    done
    echo "Error: asc CLI not found. Set ASC_BIN to the path of the asc binary." >&2
    echo "  Install from: https://github.com/bitrig/asc or Bitrig.app" >&2
    exit 1
}

ASC="$(resolve_asc)"

# --- Check auth ---
if ! "$ASC" auth status >/dev/null 2>&1; then
    echo "Error: asc is not authenticated. Run: $ASC auth login" >&2
    exit 1
fi

# --- Resolve app ID ---
echo "Looking up app: $BUNDLE_ID" >&2
APP_JSON="$("$ASC" apps list --bundle-id "$BUNDLE_ID" --output json 2>&1)"
APP_ID="$(echo "$APP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)" || {
    echo "Error: could not find app with bundle ID $BUNDLE_ID" >&2
    exit 1
}
APP_NAME="$(echo "$APP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['attributes']['name'])" 2>/dev/null)"
echo "Found: $APP_NAME (ID: $APP_ID)" >&2

# --- Resolve pre-release version filter ---
PRV_FILTER=()
if [[ -n "$VERSION" ]]; then
    echo "Looking up pre-release version: $VERSION" >&2
    PRV_JSON="$("$ASC" testflight pre-release list --app "$APP_ID" --output json 2>&1)"
    PRV_ID="$(echo "$PRV_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
v = '$VERSION'
for item in d['data']:
    if item['attributes']['version'] == v:
        print(item['id'])
        sys.exit(0)
print('')
" 2>/dev/null)"
    if [[ -z "$PRV_ID" ]]; then
        echo "Error: version $VERSION not found. Available versions:" >&2
        echo "$PRV_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d['data']:
    print(f\"  {item['attributes']['version']}\")" >&2
        exit 1
    fi
    echo "Matched pre-release version ID: $PRV_ID" >&2
    PRV_FILTER=(--build-pre-release-version "$PRV_ID")
fi

# --- Fetch feedback ---
echo "Fetching feedback..." >&2
FEEDBACK_JSON="$("$ASC" testflight feedback list \
    --app "$APP_ID" \
    ${PRV_FILTER[@]+"${PRV_FILTER[@]}"} \
    --include-screenshots \
    --paginate \
    --output json 2>&1)"

SCREENSHOT_DIR=""
if [[ "$DOWNLOAD_SCREENSHOTS" == "1" ]]; then
    SCREENSHOT_DIR="$OUTPUT_DIR/${VERSION:-all}"
    mkdir -p "$SCREENSHOT_DIR"
    echo "Screenshots will be saved to: $SCREENSHOT_DIR" >&2
fi

FEEDBACK_JSON="$(printf '%s' "$FEEDBACK_JSON" | python3 -c "
import json, os, pathlib, sys, urllib.parse, urllib.request
from datetime import datetime, timezone

payload = json.load(sys.stdin)
since_raw = os.environ.get('SINCE', '').strip()
until_raw = os.environ.get('UNTIL', '').strip()
download = os.environ.get('DOWNLOAD_SCREENSHOTS', '0') == '1'
screenshot_dir = os.environ.get('SCREENSHOT_DIR', '').strip()

def parse_ts(value):
    if not value:
        return None
    raw = value.strip()
    if raw.endswith('Z'):
        raw = raw[:-1] + '+00:00'
    parsed = datetime.fromisoformat(raw)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.now().astimezone().tzinfo)
    return parsed.astimezone(timezone.utc)

since = parse_ts(since_raw)
until = parse_ts(until_raw)

filtered = []
for item in payload.get('data', []):
    created = parse_ts(item.get('attributes', {}).get('createdDate', ''))
    if created is None:
        continue
    if since and created < since:
        continue
    if until and created > until:
        continue
    if download and screenshot_dir:
        attrs = item.setdefault('attributes', {})
        downloaded = []
        for index, screenshot in enumerate(attrs.get('screenshots', []) or [], start=1):
            url = screenshot.get('url')
            if not url:
                continue
            suffix = pathlib.Path(urllib.parse.urlparse(url).path).suffix or '.jpg'
            target = pathlib.Path(screenshot_dir) / f\"{item.get('id', 'feedback')}-{index}{suffix}\"
            try:
                with urllib.request.urlopen(url, timeout=30) as response:
                    target.write_bytes(response.read())
                downloaded.append(str(target))
            except Exception as exc:
                downloaded.append(f'download_failed: {exc}')
        if downloaded:
            attrs['downloadedScreenshotPaths'] = downloaded
    filtered.append(item)

payload['data'] = filtered
print(json.dumps(payload))
")"

TOTAL="$(echo "$FEEDBACK_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']))")"
echo "Found $TOTAL feedback submission(s)" >&2

if [[ "$TOTAL" -eq 0 ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        printf '{"data":[]}\n'
    else
        echo "No feedback found${VERSION:+ for version $VERSION}."
    fi
    exit 0
fi

# --- Output: raw JSON ---
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "$FEEDBACK_JSON" | python3 -m json.tool
    exit 0
fi

# --- Output: markdown table ---
if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
    "$ASC" testflight feedback list \
        --app "$APP_ID" \
        ${PRV_FILTER[@]+"${PRV_FILTER[@]}"} \
        --include-screenshots \
        --paginate \
        --output markdown 2>&1
    exit 0
fi

# --- Output: summary (default) ---
echo "$FEEDBACK_JSON" | python3 -c "
import sys, json, subprocess, os

data = json.load(sys.stdin)['data']
download = '$DOWNLOAD_SCREENSHOTS' == '1'
screenshot_dir = '$SCREENSHOT_DIR'
version = '$VERSION' or 'all versions'

# Device model mapping (common models)
DEVICES = {
    'iPhone14_2': 'iPhone 13 Pro',
    'iPhone15_3': 'iPhone 14 Pro Max',
    'iPhone16_1': 'iPhone 15 Pro',
    'iPhone16_2': 'iPhone 15 Pro Max',
    'iPhone17_1': 'iPhone 16 Pro',
    'iPhone17_2': 'iPhone 16 Pro Max',
    'iPhone18_1': 'iPhone 17 Pro',
    'iPhone18_2': 'iPhone 17 Pro Max',
    'iPhone18_3': 'iPhone 17',
    'iPad13_1': 'iPad Air 4',
}

print(f'# TestFlight Feedback — {version}')
print(f'**{len(data)} submission(s)**\n')

for i, item in enumerate(data, 1):
    attrs = item['attributes']
    date = attrs['createdDate'][:10]
    comment = attrs.get('comment', '').strip()
    email = attrs.get('email', '')
    model_raw = attrs.get('deviceModel', '')
    model = DEVICES.get(model_raw, model_raw)
    os_ver = attrs.get('osVersion', '')
    screenshots = attrs.get('screenshots', [])
    downloaded_paths = attrs.get('downloadedScreenshotPaths', [])

    print(f'## #{i} — {date}')
    print(f'**Device:** {model} (iOS {os_ver})')
    if email:
        print(f'**Email:** {email}')
    if comment:
        print(f'\n> {comment}\n')
    else:
        print(f'\n> *(no comment, screenshot only)*\n')

    if screenshots:
        print(f'**Screenshots:** {len(screenshots)}')
        for j, ss in enumerate(screenshots):
            url = ss['url']
            w, h = ss.get('width', '?'), ss.get('height', '?')
            print(f'  - [{w}x{h}]({url})')
            if j-1 < len(downloaded_paths):
                print(f'    Saved: {downloaded_paths[j-1]}')
            elif download and screenshot_dir:
                fname = f'feedback-{i}-screenshot-{j+1}.jpg'
                fpath = os.path.join(screenshot_dir, fname)
                try:
                    subprocess.run(['curl', '-sL', '-o', fpath, url], check=True, timeout=15)
                    print(f'    Saved: {fpath}')
                except Exception:
                    print(f'    (download failed)')
    print()
"
