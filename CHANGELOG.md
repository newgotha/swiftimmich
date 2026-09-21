# Changelog

## 2.6.1

- **Hover effects.** Buttons, sidebar rows and album, people and place tiles now react when the pointer is over them: buttons darken or brighten, small icon buttons get a soft highlight, sidebar rows highlight, and tiles lift slightly.
- **Clearer selection.** A selected photo or video now shrinks a little inside its cell over a light blue margin, with a blue outline and a check mark, so it's easy to tell apart from the rest.

## 2.6.0

- **Non-destructive edits.** Looks, tone and colour sliders, sharpen, vignette, warmth, straighten and crop are now saved with **Save Edit (Keep Original)**: your original is never touched, and the edited copy sits on top of it in a stack, so the Immich web and phone apps show the edited version too.
- **Re-edit anytime.** Open the Edit panel on an edited copy and the sliders come back where you left them, working from the original again. Saving replaces the old copy.
- **Remove Edit.** One button in the Edit panel puts your original back and moves the edited copy to the trash.
- **Clearer stack message.** Trying to take a stack's cover photo out of its stack now explains that Immich doesn't allow it and suggests "Unstack All".

## 2.5.0

- **Video tools.** Open one of your videos and use the new bar at the top right of the player:
  - **Trim…** downloads the original and opens an editor with a preview, a filmstrip and a handle at each end. Save it as a new video (the original is kept). The default cut is quick and lossless, at the nearest keyframe; **Exact cut** re-encodes so it lands exactly on the handles.
  - **Save Frame** saves the picture on screen, at full size, as a new photo.
  - **Speed** plays at 0.5×, 1.5× or 2×.

## 2.4.0

- **Photo editing.** The Edit panel now has one-tap **Looks** (Vivid, Dramatic, Warm, Cool, Fade, Chrome, Instant, Mono, Silvertone and Noir, with live previews and a strength slider), plus **Shadows**, **Highlights**, **Warmth**, **Sharpen** and **Vignette** sliders and a **Straighten** slider that levels a tilted horizon without leaving empty corners. Looks and these adjustments are saved as a new photo or over the original, like colour edits.
- **Crop presets.** Freeform, Original, Square, 3:2, 4:3, 16:9 and 5:4, with a portrait/landscape switch; the shape holds as you drag the corners.
- **Revert to Original.** Photos with a saved crop, rotation or mirror can be put back with one button.

## 2.3.0

- **Album tools.** Download a whole album as a zip file (large albums are split into several), drag albums into your own order in the sidebar, and give an album a description.
- **Locations.** "Show on Map" from a photo's right-click menu or its info panel, and a map in the details editor where you click or drag a pin to correct where a photo was taken.
- **Notifications.** When an import from Photos finishes, stops or has problems, and when someone comments in one of your shared albums — shown only while SwiftImmich isn't the app you're using, and switched off in Settings if you like.
- **Homebrew.** `brew install --cask newgotha/swiftimmich/swiftimmich`.

## 2.2.0

- **Freeze protection.** If the window ever stops responding, the app now saves a technical snapshot and offers to attach a summary to **Help > Report a Problem…**, so a freeze can be diagnosed instead of guessed at.
- **Faster with big libraries.**
  - All Photos and Years now show months in batches while they load, instead of redrawing the whole grid after every month. Loading a large library is far smoother.
  - Photos are laid out about 45% faster, and search results grouped by month or year no longer re-sort for every section.
  - Scrolling fast through a large library no longer starts hundreds of downloads at once: at most 8 run together, the photos on screen come first, and photos you've already scrolled past are skipped. Thumbnail memory is also capped by size, not just by count.

## 2.1.0

- **Dark mode.** The app now follows your Mac's light or dark setting. Settings (⌘,) has an **Appearance** switch — Match System, Light or Dark.
- **Keyboard navigation.** Arrow keys move a highlight around the photos in any grid; Space previews and Return opens the highlighted photo; Shift+arrows select as you go and ⌘A selects everything loaded.
- **Accessibility.** Thumbnails read as "Photo, 12 September 2026, favorite" in VoiceOver, the viewer's icon-only buttons and other controls have spoken names, the timeline scrubber can be stepped month by month, and animations stand down when "Reduce motion" is on.
- The Settings window now fits on screen and scrolls instead of growing past the Dock.

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
