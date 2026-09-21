#!/bin/bash
# Points the Homebrew cask (github.com/newgotha/homebrew-swiftimmich) at a published release.
# Run it after `gh release create`:   Scripts/update_cask.sh 2.3.0
set -euo pipefail
VERSION="${1:?usage: Scripts/update_cask.sh <version, e.g. 2.3.0>}"
REPO=newgotha/swiftimmich
TAP=newgotha/homebrew-swiftimmich

SHA=$(gh release download "v$VERSION" -R "$REPO" -p SHA256SUMS.txt -O - | awk -v f="SwiftImmich-$VERSION.zip" '$2 == f { print $1 }')
[ -n "$SHA" ] || { echo "No checksum for SwiftImmich-$VERSION.zip in release v$VERSION."; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP" "$WORK/tap" -- -q
cd "$WORK/tap"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/swiftimmich.rb

if git diff --quiet; then
    echo "The cask already points at $VERSION."
    exit 0
fi
git add Casks/swiftimmich.rb
git commit -q -m "swiftimmich $VERSION"
git push -q origin HEAD
echo "Cask updated to $VERSION ($SHA)."
