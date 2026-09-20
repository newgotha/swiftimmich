#!/bin/bash
# Installs (or updates) SwiftImmich from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/newgotha/swiftimmich/main/Scripts/install.sh | bash
#
# Files downloaded with curl aren't marked as quarantined, so macOS opens the app without
# the "Open Anyway" step that a browser download needs.
set -euo pipefail

REPO="newgotha/swiftimmich"
APP="SwiftImmich"

echo "Looking up the latest ${APP} release…"
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"
ZIP_URL="$(printf '%s' "$RELEASE_JSON" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
SUMS_URL="$(printf '%s' "$RELEASE_JSON" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS\.txt"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
TAG="$(printf '%s' "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"

if [ -z "$ZIP_URL" ]; then
    echo "Couldn't find a download in the latest release." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ${TAG}…"
curl -fL --progress-bar -o "$TMP/${APP}.zip" "$ZIP_URL"

if [ -n "$SUMS_URL" ]; then
    EXPECTED="$(curl -fsSL "$SUMS_URL" | grep "$(basename "$ZIP_URL")" | awk '{print $1}')"
    ACTUAL="$(shasum -a 256 "$TMP/${APP}.zip" | awk '{print $1}')"
    if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "The download's checksum doesn't match — not installing." >&2
        exit 1
    fi
fi

ditto -x -k "$TMP/${APP}.zip" "$TMP"

# INSTALL_DIR overrides where the app goes (default: /Applications, or ~/Applications if that
# isn't writable); NO_LAUNCH=1 skips starting it afterwards.
if [ -n "${INSTALL_DIR:-}" ]; then
    DEST_DIR="$INSTALL_DIR"
    mkdir -p "$DEST_DIR"
elif [ -w "/Applications" ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi

if [ -z "${INSTALL_DIR:-}" ] && pgrep -x "$APP" >/dev/null 2>&1; then
    echo "Quitting the running ${APP}…"
    osascript -e "tell application \"${APP}\" to quit" >/dev/null 2>&1 || true
    sleep 2
fi

rm -rf "${DEST_DIR}/${APP}.app"
ditto "$TMP/${APP}.app" "${DEST_DIR}/${APP}.app"
xattr -cr "${DEST_DIR}/${APP}.app" 2>/dev/null || true

echo "Installed ${APP} ${TAG} to ${DEST_DIR}."
if [ "${NO_LAUNCH:-0}" != "1" ]; then open "${DEST_DIR}/${APP}.app"; fi
