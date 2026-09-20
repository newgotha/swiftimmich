#!/bin/bash
# Builds SwiftImmich and installs it into /Applications (or ~/Applications) for local use.
# If Scripts/setup_signing.sh has been run, the app is signed with that local identity.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SwiftImmich"

# A stable local identity (see Scripts/setup_signing.sh) instead of an ad-hoc signature.
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null | awk '/SwiftImmich Local Signing/ {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
    export SIGN_IDENTITY="$SIGN_HASH"
else
    echo "Tip: run Scripts/setup_signing.sh once for a stable local signing identity."
fi

Scripts/build_app.sh --out dist

if [ -w "/Applications" ]; then
    INSTALL_ROOT="/Applications"
else
    INSTALL_ROOT="$HOME/Applications"
    mkdir -p "$INSTALL_ROOT"
fi
APP_DIR="$INSTALL_ROOT/${APP_NAME}.app"

rm -rf "$APP_DIR"
ditto "dist/${APP_NAME}.app" "$APP_DIR"
echo "Installed to $APP_DIR"
