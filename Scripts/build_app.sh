#!/bin/bash
# Builds SwiftImmich.app.
#
#   Scripts/build_app.sh [--universal] [--out DIR]
#
#   --universal   build for both Apple silicon and Intel (slower; used for releases)
#   --out DIR     where to put SwiftImmich.app (default: dist)
#
# Environment:
#   SIGN_IDENTITY   codesign identity; "-" (the default) is an ad-hoc signature.
#                   Use "Developer ID Application: Your Name (TEAMID)" for a notarizable build.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SwiftImmich"
BUNDLE_ID="dev.local.swiftimmich"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ICON_MASTER="Scripts/immich-icon-master.png"
ICON_ICNS="Scripts/AppIcon.icns"
OUT="dist"
ARCH_FLAGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        --out) OUT="$2"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

echo "Building ${APP_NAME} ${VERSION} (release${ARCH_FLAGS:+, universal})…"
swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

echo "Building icon from ${ICON_MASTER}…"
ICONSET="$(mktemp -d)/${APP_NAME}.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICON_ICNS"

APP_DIR="${OUT}/${APP_NAME}.app"
echo "Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "$APP_DIR/Contents/MacOS/${APP_NAME}"
# Drop the debug-map entries that point back into the build folder. Without this, the freeze
# watchdog's stack sample (which runs as a child of the app) stalls trying to read them from
# ~/Documents, where macOS asks the app for permission. Function names are kept.
strip -S "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Self-hosted Immich servers are often reached over plain http:// on a home network,
             at an address the app can't know in advance, so http:// is allowed. The connection
             form warns when an http:// address points beyond your own network. -->
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>Released under the MIT License. Not affiliated with the Immich project.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>SwiftImmich reads your Photos library so it can copy your photos and videos, including ones stored in iCloud, to your Immich server. Nothing in Photos is changed or deleted.</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Code-signing (ad hoc)…"
else
    echo "Code-signing with ${SIGN_IDENTITY}…"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "Built ${APP_DIR}"
