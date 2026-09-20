# Publishing a release

Users get updates from GitHub Releases: the app checks the repository's **latest release** and, if its tag is newer than the running version, offers to download it.

## Steps

1. Change the number in `VERSION` (for example `1.0.1`) and add a section to `CHANGELOG.md`.
2. Commit, then tag it and push:

   ```bash
   git add -A && git commit -m "Release 1.0.1"
   git tag v1.0.1
   git push && git push origin v1.0.1
   ```

3. The **Release** workflow (`.github/workflows/release.yml`) builds a universal `.dmg` and `.zip` and attaches them to a new GitHub release, using the tag as the version. To build by hand instead:

   ```bash
   Scripts/package_release.sh
   gh release create v1.0.1 dist/SwiftImmich-1.0.1.dmg dist/SwiftImmich-1.0.1.zip dist/SHA256SUMS.txt \
       --title "SwiftImmich 1.0.1" --notes-file CHANGELOG.md
   ```

   or create the release on github.com and upload the files from `dist/`.

The tag must look like `v1.2.3`, and the release must **not** be a draft or a pre-release, or the in-app update check ignores it.

## Notarization (optional)

Without an Apple Developer ID the app can't be notarized, so first-time users must use **Open Anyway** (see the README). With a paid developer account:

```bash
xcrun notarytool store-credentials swiftimmich-notary      # one time
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=swiftimmich-notary Scripts/package_release.sh
```

## Automatic in-place updates

Today an update is a manual download. If you want the app to download and install itself, the usual route is the [Sparkle](https://sparkle-project.org) framework, which needs an appcast feed and an update-signing key; it can be added later without changing how releases are published.
