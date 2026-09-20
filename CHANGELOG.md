# Changelog

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
