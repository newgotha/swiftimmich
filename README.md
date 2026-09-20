# SwiftImmich

A native macOS app for [Immich](https://immich.app), the self-hosted photo library. It looks and behaves like the Photos app, and it can import your Mac's Photos library (including photos that only live in iCloud) into your Immich server.

> **Unofficial.** SwiftImmich is an independent project and is not affiliated with or endorsed by the Immich project. "Immich" and its logo belong to their owners; the app icon uses the Immich logo to show what it connects to. If the Immich team would like it changed, it will be.

## Features

- **Browse** your library in a justified grid with All Photos / Months / Years, a full-screen viewer (swipe or arrow keys), info panel, Live Photos and slideshows.
- **Organise**: albums (with sharing, roles, comments and likes), public share links, tags, star ratings, favorites, archive, stacks, duplicates review, Recently Deleted and a PIN-protected Locked Folder.
- **Find**: search with filters (people, place, date, camera, rating) and saved searches, a map of your photos, People with face naming, and "On this day" memories.
- **Edit**: rotate, mirror, crop, colour adjustments and Auto Enhance — saved as a new photo or over the original.
- **Import** your Photos library, including iCloud originals, automatically for new photos, with a menu bar status item and a Backup Check that finds anything missing.
- **Keyboard and gestures**: Space for Quick Look, Return to open, F to favourite, 1–5 to rate, S for a slideshow, and two-finger swipes in the viewer.
- Works offline for what you have already viewed.

## Requirements

- macOS 14 or later (Apple silicon or Intel)
- An Immich server and an [API key](https://immich.app/docs/features/command-line-interface#obtain-the-api-key) (Account Settings → API Keys). Give the key all permissions, or the app won't be able to do everything it offers.

## Install

**Recommended — one line in Terminal** (no macOS security prompt):

```bash
curl -fsSL https://raw.githubusercontent.com/newgotha/swiftimmich/main/Scripts/install.sh | bash
```

This downloads the latest release, checks its checksum, installs it in Applications and opens it. macOS only blocks apps that were downloaded by a *browser*, so an app fetched this way opens normally.

**Or download it yourself:**

1. Download the latest `SwiftImmich-x.y.z.dmg` from the [Releases page](https://github.com/newgotha/swiftimmich/releases), open it and drag **SwiftImmich** into **Applications**.
2. Because the app isn't notarized by Apple (that needs a paid developer account) and a browser download is flagged, macOS will refuse to open it the first time. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to SwiftImmich (or run `xattr -dr com.apple.quarantine /Applications/SwiftImmich.app`).

Then click the server icon in the toolbar and enter your server address (for example `https://photos.example.com`) and your API key.

## Updating

SwiftImmich checks GitHub for a newer release about once a day (**SwiftImmich → Check for Updates…**, or **Settings → Updates**). When there is one, click **Install and Restart**: the app downloads the update, verifies it, replaces itself and reopens, with no security prompt. Your settings and server connection are kept.

## Good to know

- **Your API key** is stored in an encrypted file in `~/Library/Application Support/SwiftImmich`, readable only by your account, and is sent only to your server. The app has no analytics and talks to no server except yours (and GitHub for the update check).
- **http:// servers** on your home network (for example `http://192.168.1.20:2283`) work. The connection form warns if you enter an `http://` address that isn't on your own network, because your API key would cross the internet unencrypted.
- **Cloudflare** rejects any single upload over about 100 MB. If your server is behind it, add a direct address for large files under **Settings → Large files** (it only works on the same network as the server).
- **Locked Folder**: Immich only shows locked photos to a signed-in session, so the app asks you to sign in once with your email and password. The password is never saved; only the resulting session is.
- **Problems**: **Help → Show Error Log** reveals `~/Library/Logs/SwiftImmich.log`. Please include the relevant lines when you report a bug.

## Building from source

Building needs Xcode 26 or later (the macOS 26 SDK).

```bash
git clone https://github.com/newgotha/swiftimmich.git
cd swiftimmich
swift test                      # run the tests
Scripts/build_and_install.sh    # build and install to /Applications
Scripts/package_release.sh      # build a universal .dmg and .zip in dist/
```

See [RELEASING.md](RELEASING.md) for how releases are published.

## License

[MIT](LICENSE)
