#!/usr/bin/env bash
# Mac Catalyst direct distribution (Developer ID + notarization).
#
# Pipeline:
#   1. Archive `LitterMac` for Mac Catalyst.
#   2. Export with method=developer-id → produces a Developer ID-signed .app.
#   3. Wrap the .app + /Applications shortcut in a styled .dmg via hdiutil.
#   4. Sign the .dmg with the Developer ID Application cert so Gatekeeper
#      trusts the container itself, not just the inner .app.
#   5. Submit the .dmg to Apple's notary service via `xcrun notarytool`
#      using the same ASC API key the TestFlight flow uses.
#   6. Staple the notarization ticket to the .dmg so it passes Gatekeeper
#      offline after the first run.
#
# Output: `$BUILD_DIR/Litter-<version>-mac.dmg`, ready to host anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

SCHEME="${SCHEME:-LitterMac}"
# `DeveloperID` is the unsandboxed Mac Catalyst configuration defined in
# project.yml; it picks up Litter-Catalyst-DeveloperID.entitlements so the
# notarized .dmg can spawn a local `codex app-server`. The Mac App Store
# (TestFlight) lane uses Release, which keeps the sandbox.
CONFIGURATION="${CONFIGURATION:-DeveloperID}"
PROJECT_DIR="${PROJECT_DIR:-$IOS_DIR}"
PROJECT_PATH="${PROJECT_PATH:-$PROJECT_DIR/Litter.xcodeproj}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Litter}"
TEAM_ID="${TEAM_ID:-}"
# Developer ID provisioning profile name (NOT the Mac App Store one).
# Required because our entitlements include APS + App Groups (and iCloud
# KVS when Feature C activates) — all three are silently stripped from
# the signed .app unless a matching profile authorizes them.
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-Litter Developer ID}"
APP_PROVISIONING_PROFILE_SPECIFIER="${APP_PROVISIONING_PROFILE_SPECIFIER:-$PROVISIONING_PROFILE_SPECIFIER}"
# Code sign identity for the .app bundle. `Developer ID Application` is the
# exact CN prefix Apple uses; `security find-identity` will confirm it.
APP_CODE_SIGN_IDENTITY="${APP_CODE_SIGN_IDENTITY:-Developer ID Application}"
# Manual signing so xcodebuild doesn't auto-pick the iOS / Apple
# Distribution cert instead of Developer ID Application. Same lesson as
# testflight-upload-mac.sh — automatic signing is too willing to grab the
# wrong identity when multiple are in the keychain.
EXPORT_SIGNING_STYLE="${EXPORT_SIGNING_STYLE:-manual}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
NOTARIZATION_TIMEOUT="${NOTARIZATION_TIMEOUT:-30m}"

AUTH_KEY_PATH="${AUTH_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
AUTH_KEY_ID="${AUTH_KEY_ID:-${ASC_KEY_ID:-}}"
AUTH_ISSUER_ID="${AUTH_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build/direct-dist-mac}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGING_DIR="$BUILD_DIR/dmg-stage"
DMG_MOUNT_DIR="$BUILD_DIR/dmg-mount"
DMG_BACKGROUND_SOURCE="${DMG_BACKGROUND_SOURCE:-$ROOT_DIR/services/website/public/brand_logo.png}"
DMG_SKIP_FINDER_LAYOUT="${DMG_SKIP_FINDER_LAYOUT:-0}"

require_cmd jq
require_cmd xcodebuild
require_cmd xcodegen
require_cmd hdiutil

create_dmg_background() {
    local output_path="$1"
    local brand_path="$2"
    local swift_file="$BUILD_DIR/create-dmg-background.swift"

    if ! command -v swift >/dev/null 2>&1; then
        echo "==> swift not found; skipping DMG background generation"
        return 1
    fi

    cat >"$swift_file" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let brandPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let size = NSSize(width: 620, height: 370)
let image = NSImage(size: size)

image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.035, green: 0.034, blue: 0.030, alpha: 1).setFill()
bounds.fill()

let gridColor = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.22, alpha: 0.22)
gridColor.setStroke()
for x in stride(from: 28.0, through: Double(size.width), by: 28.0) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: 0))
    path.line(to: NSPoint(x: x, y: Double(size.height)))
    path.lineWidth = 0.5
    path.stroke()
}
for y in stride(from: 28.0, through: Double(size.height), by: 28.0) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 0, y: y))
    path.line(to: NSPoint(x: Double(size.width), y: y))
    path.lineWidth = 0.5
    path.stroke()
}

let accent = NSColor(calibratedRed: 0.0, green: 1.0, blue: 0.612, alpha: 1)
accent.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size.width, height: 5), xRadius: 0, yRadius: 0).fill()

let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: titleStyle
]
"Install Litter".draw(
    in: NSRect(x: 0, y: 42, width: size.width, height: 28),
    withAttributes: titleAttributes
)

let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.78, alpha: 1),
    .paragraphStyle: titleStyle
]
"Drag Litter.app into Applications".draw(
    in: NSRect(x: 0, y: 72, width: size.width, height: 22),
    withAttributes: subtitleAttributes
)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 245, y: 205))
arrow.line(to: NSPoint(x: 375, y: 205))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
accent.setStroke()
arrow.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 375, y: 205))
head.line(to: NSPoint(x: 354, y: 191))
head.line(to: NSPoint(x: 354, y: 219))
head.close()
accent.setFill()
head.fill()

if let brand = NSImage(contentsOfFile: brandPath) {
    brand.draw(
        in: NSRect(x: 265, y: 258, width: 90, height: 90),
        from: .zero,
        operation: .sourceOver,
        fraction: 0.72
    )
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("Unable to render DMG background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

    swift "$swift_file" "$output_path" "$brand_path"
    if command -v sips >/dev/null 2>&1; then
        sips -z 370 620 "$output_path" >/dev/null
    fi
}

apply_dmg_finder_layout() {
    local volume_name="$1"
    local mount_dir="$2"

    if [[ "$DMG_SKIP_FINDER_LAYOUT" == "1" ]]; then
        echo "==> Skipping Finder DMG layout (DMG_SKIP_FINDER_LAYOUT=1)"
        return 0
    fi
    if ! command -v osascript >/dev/null 2>&1; then
        echo "==> osascript not found; skipping Finder DMG layout"
        return 0
    fi

    chflags hidden "$mount_dir/.background" 2>/dev/null || true
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a V "$mount_dir/.background" 2>/dev/null || true
    fi

    if ! osascript <<OSA
tell application "Finder"
    tell disk "$volume_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 740, 490}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 112
        set text size of theViewOptions to 13
        if exists file ".background:background.png" then
            set background picture of theViewOptions to file ".background:background.png"
        end if
        set position of item "$APP_DISPLAY_NAME.app" of container window to {170, 210}
        set position of item "Applications" of container window to {450, 210}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
    then
        echo "==> Finder DMG layout failed; continuing with app + Applications shortcut"
    fi
}

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
    if [[ -z "$AUTH_KEY_PATH" || -z "$AUTH_KEY_ID" || -z "$AUTH_ISSUER_ID" ]]; then
        echo "Notarization requires AUTH_KEY_PATH / AUTH_KEY_ID / AUTH_ISSUER_ID (or the ASC_* equivalents)." >&2
        echo "Set SKIP_NOTARIZATION=1 to build an un-notarized .dmg for local testing." >&2
        exit 1
    fi
fi

if [[ "$EXPORT_SIGNING_STYLE" != "automatic" && "$EXPORT_SIGNING_STYLE" != "manual" ]]; then
    echo "Unsupported EXPORT_SIGNING_STYLE: $EXPORT_SIGNING_STYLE" >&2
    echo "Expected 'automatic' or 'manual'." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$EXPORT_DIR"
rm -rf "${ARCHIVE_PATH:?}" "${EXPORT_DIR:?}"/*

if [[ -z "$MARKETING_VERSION" ]]; then
    MARKETING_VERSION="$(read_project_marketing_version)"
fi
ensure_semver "$MARKETING_VERSION"

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(date +%Y%m%d%H%M)"
fi

TEAM_ID="$(resolve_team_id "$TEAM_ID" "$PROJECT_PATH" "$SCHEME" "$CONFIGURATION" "$EXPORT_SIGNING_STYLE" "$APP_PROVISIONING_PROFILE_SPECIFIER")"

auth_args=()
if [[ -n "$AUTH_KEY_PATH" && -n "$AUTH_KEY_ID" && -n "$AUTH_ISSUER_ID" ]]; then
    auth_args=(
        -authenticationKeyPath "$AUTH_KEY_PATH"
        -authenticationKeyID "$AUTH_KEY_ID"
        -authenticationKeyIssuerID "$AUTH_ISSUER_ID"
    )
fi

echo "==> Regenerating Xcode project"
"$PROJECT_DIR/scripts/regenerate-project.sh"

echo "==> Archiving $SCHEME ($MARKETING_VERSION/$BUILD_NUMBER) for Mac Catalyst"
archive_cmd=(
    xcodebuild
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=macOS,variant=Mac Catalyst"
    -archivePath "$ARCHIVE_PATH"
    clean archive
    MARKETING_VERSION="$MARKETING_VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    ARCHS=arm64
    ONLY_ACTIVE_ARCH=NO
)

if [[ -n "$TEAM_ID" ]]; then
    archive_cmd+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
    archive_cmd+=(
        APP_CODE_SIGN_STYLE=Manual
        APP_CODE_SIGN_IDENTITY="$APP_CODE_SIGN_IDENTITY"
        ENABLE_HARDENED_RUNTIME=YES
    )
    if [[ -n "$APP_PROVISIONING_PROFILE_SPECIFIER" ]]; then
        archive_cmd+=(APP_PROVISIONING_PROFILE_SPECIFIER="$APP_PROVISIONING_PROFILE_SPECIFIER")
    fi
else
    archive_cmd+=(-allowProvisioningUpdates)
fi

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
    archive_cmd+=("${auth_args[@]}")
fi

"${archive_cmd[@]}"

cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>${EXPORT_SIGNING_STYLE}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF

if [[ -n "$TEAM_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
fi
if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -n "$APP_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $APP_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
    # Same story as mac-testflight: pin the signing cert so xcodebuild
    # doesn't auto-select whatever it finds first in the keychain.
    /usr/libexec/PlistBuddy -c "Add :signingCertificate string $APP_CODE_SIGN_IDENTITY" "$EXPORT_OPTIONS_PLIST"
fi

echo "==> Exporting Developer ID-signed .app"
export_cmd=(
    xcodebuild
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" ]]; then
    export_cmd+=(-allowProvisioningUpdates)
fi

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
    export_cmd+=("${auth_args[@]}")
fi

"${export_cmd[@]}"

# Exported path shape for developer-id is $EXPORT_DIR/<AppName>.app
APP_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -type d -name "*.app" | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
    echo "No .app produced in $EXPORT_DIR" >&2
    exit 1
fi
echo "==> Exported app: $APP_PATH"

# Xcode's Catalyst developer-id export can preserve the Developer ID identity
# while still omitting the hardened runtime flag. Re-sign the exported app
# before DMG packaging so Apple's notary service sees runtime on every slice.
echo "==> Re-signing exported app with hardened runtime"
APP_ENTITLEMENTS_PLIST="$BUILD_DIR/exported-app-entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" >"$APP_ENTITLEMENTS_PLIST" 2>/dev/null || true
resign_cmd=(
    codesign
    --force
    --sign "$APP_CODE_SIGN_IDENTITY"
    --timestamp
    --options runtime
)
if [[ -s "$APP_ENTITLEMENTS_PLIST" ]]; then
    resign_cmd+=(--entitlements "$APP_ENTITLEMENTS_PLIST")
fi
resign_cmd+=("$APP_PATH")
"${resign_cmd[@]}"

# Verify the .app signature before wrapping. Gatekeeper assessment must wait
# until after notarization; otherwise spctl correctly rejects valid Developer ID
# apps as "Unnotarized Developer ID" before notarytool has run.
echo "==> Verifying .app Developer ID signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n '/Runtime Version/p;/flags=/p'

DMG_NAME="${APP_DISPLAY_NAME}-${MARKETING_VERSION}-mac.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_RW_PATH="$BUILD_DIR/${APP_DISPLAY_NAME}-${MARKETING_VERSION}-mac-rw.dmg"
rm -f "$DMG_PATH" "$DMG_RW_PATH"
rm -rf "$DMG_STAGING_DIR" "$DMG_MOUNT_DIR"
mkdir -p "$DMG_STAGING_DIR/.background" "$DMG_MOUNT_DIR"

echo "==> Building $DMG_NAME"
# Stage the app next to an /Applications symlink so the mounted image behaves
# like the conventional drag-to-install Mac DMGs users expect.
ditto "$APP_PATH" "$DMG_STAGING_DIR/$APP_DISPLAY_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

DMG_BACKGROUND_PATH="$DMG_STAGING_DIR/.background/background.png"
if [[ -f "$DMG_BACKGROUND_SOURCE" ]]; then
    create_dmg_background "$DMG_BACKGROUND_PATH" "$DMG_BACKGROUND_SOURCE" || true
fi

# Build a temporary read/write image first so Finder can write .DS_Store layout
# metadata, then compress that exact volume into the final read-only image.
hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDRW \
    "$DMG_RW_PATH" >/dev/null

hdiutil attach "$DMG_RW_PATH" -mountpoint "$DMG_MOUNT_DIR" -nobrowse -noverify -noautoopen >/dev/null
detach_target="$DMG_MOUNT_DIR"
cleanup_dmg_mount() {
    if [[ -n "${detach_target:-}" ]]; then
        hdiutil detach "$detach_target" -quiet >/dev/null 2>&1 || hdiutil detach "$detach_target" -force -quiet >/dev/null 2>&1 || true
        detach_target=""
    fi
}
trap cleanup_dmg_mount EXIT

apply_dmg_finder_layout "$APP_DISPLAY_NAME" "$DMG_MOUNT_DIR"
sync
cleanup_dmg_mount
trap - EXIT

# UDZO = zlib-compressed read-only. Standard for distribution DMGs.
hdiutil convert "$DMG_RW_PATH" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null
rm -f "$DMG_RW_PATH"
rm -rf "$DMG_STAGING_DIR" "$DMG_MOUNT_DIR"

echo "==> Signing .dmg with $APP_CODE_SIGN_IDENTITY"
codesign \
    --sign "$APP_CODE_SIGN_IDENTITY" \
    --timestamp \
    "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
    echo "==> Skipping notarization (SKIP_NOTARIZATION=1)"
    echo "==> Direct distribution build complete (UN-NOTARIZED)"
    echo "    DMG:         $DMG_PATH"
    echo "    Version:     $MARKETING_VERSION"
    echo "    Build:       $BUILD_NUMBER"
    echo
    echo "    NOTE: Gatekeeper will refuse to launch this .dmg on other Macs"
    echo "    until it is notarized."
    exit 0
fi

echo "==> Submitting $DMG_NAME to Apple's notary service (timeout: $NOTARIZATION_TIMEOUT)"
NOTARY_LOG="$BUILD_DIR/notarytool-submit.json"
if ! xcrun notarytool submit "$DMG_PATH" \
        --key "$AUTH_KEY_PATH" \
        --key-id "$AUTH_KEY_ID" \
        --issuer "$AUTH_ISSUER_ID" \
        --wait \
        --timeout "$NOTARIZATION_TIMEOUT" \
        --output-format json > "$NOTARY_LOG"; then
    echo "notarytool submission failed. Response:" >&2
    cat "$NOTARY_LOG" >&2 || true
    exit 1
fi

notary_status="$(jq -r '.status // empty' "$NOTARY_LOG")"
notary_id="$(jq -r '.id // empty' "$NOTARY_LOG")"
echo "==> Notary status: $notary_status (submission $notary_id)"

if [[ "$notary_status" != "Accepted" ]]; then
    echo "Notarization did not succeed. Fetching detailed log..." >&2
    if [[ -n "$notary_id" ]]; then
        notary_detail_log="$BUILD_DIR/notarytool-log.json"
        xcrun notarytool log "$notary_id" \
            --key "$AUTH_KEY_PATH" \
            --key-id "$AUTH_KEY_ID" \
            --issuer "$AUTH_ISSUER_ID" \
            "$notary_detail_log" || true
        if [[ -s "$notary_detail_log" ]]; then
            echo "Detailed notary log:" >&2
            jq . "$notary_detail_log" >&2 || cat "$notary_detail_log" >&2
        fi
        echo "Detailed log: $notary_detail_log" >&2
    fi
    exit 1
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# Cross-check that the stapled ticket actually passes Gatekeeper offline.
# spctl on the .dmg confirms the container will be accepted; spctl on the
# mounted .app is the real "will this launch" check and is worth doing
# here in CI so a bad notarization fails the job rather than only failing
# on a user's Mac.
echo "==> Final Gatekeeper assessment on the .dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

echo "==> Direct distribution build complete"
echo "    DMG:         $DMG_PATH"
echo "    Version:     $MARKETING_VERSION"
echo "    Build:       $BUILD_NUMBER"
echo "    Notary ID:   $notary_id"
