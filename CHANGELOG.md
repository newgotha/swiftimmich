# Changelog

## 2.0.0

- **Timeline scrubber.** A date strip on the right edge of the Months and Years views: click or drag to jump to any month in a large library.
- **Thumbnail size.** A slider on every photo page, plus ⌘+, ⌘− and ⌘0 in the View menu.
- **People management.** Favourite people (shown first), hide and unhide them, set birthdays, and choose a person's cover photo from their grid.
- **Welcome page.** First launch explains the server address and API key and tests the connection before continuing.
- **Help > Report a Problem…** copies your app and macOS versions and the recent error log so you can paste them into a GitHub issue.

## 1.0.3

- The Storage page now sits in a centred card like the other tool pages.

## 1.0.2

- **Updates install themselves.** When a new version is available, **Install and Restart** downloads it, checks its checksum and signature, replaces the app and reopens it — with no macOS security prompt.
- **One-line installer** (`Scripts/install.sh`) for the first install, which also avoids the "Open Anyway" step.

## 1.0.1

- Servers reached over plain `http://` (for example `http://192.168.1.20:2283`) now work; macOS was blocking them. The connection form warns when an `http://` address is beyond your own network, and a server address typed without `https://` is assumed to be https.
- Connection problems now say what went wrong in plain English (offline, server not found, timed out, certificate problem, API key refused) instead of a long technical dump.

## 1.0.0

First release.

- Browse your Immich library like the Photos app: justified grid, All Photos / Months / Years, a full-screen viewer with swipe gestures, info panel, slideshow and Live Photos.
- Albums (including shared albums with activity, roles and public links), People (naming faces, face outlines), Places, Map, Memories with "On this day", tags, ratings and search with filters and saved searches.
- Editing: rotate, mirror, crop and colour adjustments with Auto Enhance; save as a new photo or replace the original.
- Import your Mac's Photos library (including iCloud originals), automatically for new photos, with a menu bar status item and a backup check.
- Duplicates review, stacks, storage clean-up, Recently Deleted, Locked Folder, partner sharing.
- Multi-select, drag and drop, Quick Look with Space, keyboard shortcuts, offline browsing of what you've seen, in-app update check.
