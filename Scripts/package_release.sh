#!/bin/bash
# Builds a universal SwiftImmich and packages it for a GitHub release:
#   dist/SwiftImmich-<version>.zip, dist/SwiftImmich-<version>.dmg, dist/SHA256SUMS.txt
#
# Environment:
#   SIGN_IDENTITY   codesign identity (default: ad hoc). See build_app.sh.
#   NOTARY_PROFILE  a `notarytool store-credentials` profile name. When set (with a
#                   Developer ID SIGN_IDENTITY), the DMG is notarized and stapled so it opens
#                   without Gatekeeper warnings. Needs an Apple Developer account.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SwiftImmich"
VERSION="$(tr -d '[:space:]' < VERSION)"
OUT="dist"

Scripts/build_app.sh --universal --out "$OUT"

ZIP="${OUT}/${APP_NAME}-${VERSION}.zip"
DMG="${OUT}/${APP_NAME}-${VERSION}.dmg"
rm -f "$ZIP" "$DMG"

echo "Creating ${ZIP}…"
ditto -c -k --sequesterRsrc --keepParent "${OUT}/${APP_NAME}.app" "$ZIP"

echo "Creating ${DMG}…"
STAGE="$(mktemp -d)"
ditto "${OUT}/${APP_NAME}.app" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notarizing ${DMG} (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

( cd "$OUT" && shasum -a 256 "${APP_NAME}-${VERSION}.zip" "${APP_NAME}-${VERSION}.dmg" > SHA256SUMS.txt )

echo
echo "Release files in ${OUT}/:"
ls -lh "$ZIP" "$DMG" "${OUT}/SHA256SUMS.txt"
lipo -archs "${OUT}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" | sed 's/^/Architectures: /'
