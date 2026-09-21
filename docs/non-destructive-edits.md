# Non-destructive edits beyond crop and rotate

Status: **built (option B + C) and released in 2.6.0** (idea written 2026-09-21, after 2.4.0).

## The problem

SwiftImmich 2.4 can apply looks, tone and colour sliders, sharpen, vignette, warmth and straighten. Immich
can only store crop, rotate and mirror as edits, so everything else has to be **baked into a new file**:
"Save as New Photo", or "Replace Original" (upload the new file, trash the old one — not undoable).

We want these edits to stay **editable and reversible**, and ideally to show up in the Immich web and phone apps.

## What the server actually offers (Immich 3.2.0 API, checked in `Sources/ImmichAPI/openapi.json`)

- **Edits API** (`PUT/GET/DELETE /assets/{id}/edits`): actions are exactly `crop`, `rotate`, `mirror`.
  The server renders these itself, so thumbnails, previews and downloads all show them.
- **Asset metadata** (`GET/PUT /assets/{id}/metadata`, `GET/DELETE /assets/{id}/metadata/{key}`, plus bulk):
  arbitrary key → JSON-object pairs per photo. Needs the `asset.update` permission. Nothing in the API says
  other clients read these keys.
- **Plugins and workflows** (`/plugins`, `/workflows`): triggers `AssetCreate`, `AssetMetadataExtraction`,
  `AssetTagged`. Plugins are Wasm modules installed from a folder on the server, not through the API.
  Host functions reported: albums, tagging, outgoing HTTP requests.
  *Unofficial summary (DeepWiki) says plugins cannot read/write asset files, make thumbnails, create assets or
  change what clients display — confirm in Immich's own plugin docs before relying on this.*
- **Stacks** (used already for duplicates/stacks): group photos, one is the cover shown in grids.

## Options

| | Idea | Everyone sees the edit | Editable later | Effort |
|---|---|---|---|---|
| A | Add new edit actions to Immich itself (server pipeline + web + mobile) | yes | yes | very large; upstream or a fork |
| B | Save the edit **recipe** in asset metadata; SwiftImmich re-applies it | only SwiftImmich | yes | medium |
| C | B plus a **baked copy stacked with the original** | yes (stack cover) | yes | medium |
| D | Plugin / companion service on the server | plugin: no rendering; companion needs a second (non-Apple) renderer | — | large, poor value |

## Recommended: B + C in SwiftImmich

1. **Recipe.** Store `ImageAdjustments` (+ crop fractions, rotation, mirror) as versioned JSON under a key such as
   `swiftimmich.edit.v1` on the **original** asset: `{ "version": 1, "look": "vivid", "lookIntensity": 1, "warmth": 0.2, ... }`.
2. **Baked copy.** "Save" renders the JPEG as today, uploads it, and **stacks it with the original with the copy as
   the cover**, so web/phone show the edit. Copy album membership / favourite as "Replace Original" already does,
   but do **not** trash the original.
3. **Re-edit.** Opening a photo that has a recipe loads the *original* and the recipe, so sliders start where you left off.
4. **Revert.** Remove the stack's baked copy and the metadata key; the original was never touched.
5. **Marking.** Record on the copy which original + recipe version produced it, so a changed recipe replaces
   the old copy rather than adding another.

## Things to test on the real server first

- Does `PUT /assets/{id}/metadata` accept an arbitrary key such as `swiftimmich.edit.v1`, and how big a value?
- Do keys survive Immich upgrades, and appear on the copy or the original (sync semantics)?
- Stack behaviour: can the uploaded copy be made the primary? What do the web app, phone app, partner sharing,
  shared links, duplicate detection and "Free up space" do with a stack?
- RAW and HEIC originals: render from the original file, not the preview.
- Two Macs editing the same photo: last write wins? (`updatedAt` is returned, so a conflict check is possible.)
- What the Mac app does when a recipe uses a look a newer/older version doesn't know (keep `version`, ignore unknowns).

## Also worth doing separately

- **Upstream feature request** to Immich: an `adjust` edit action (brightness, contrast, saturation, warmth,
  shadows, highlights, sharpen, vignette) and a `look` action, rendered by their existing pipeline, with the
  parameter schema kept small and versioned. A working reference implementation (ours) and the tests we wrote
  (`Tests/SwiftImmichTests/EditingTests.swift`) show the maths. Discuss with maintainers before writing server code.
- **Plugins are for automation, not editing:** tag/album/lock rules for new uploads, or calling another service.

## Where the code is

- Adjustment maths and export order (straighten → orient → crop → look/tone → finishing): `Sources/SwiftImmich/ImageAdjustments.swift`, `Looks.swift`
- Edit panel: `EditControls.swift`; viewer wiring and save flow: `PhotoViewerView.swift`
  (`performColorAdjustedSave`, `saveNativeEdits`, `revertToOriginal`)
- Server calls for stacks, metadata-style updates and uploads: `ImmichService.swift`

## Suggested first step

A small spike: write and read a metadata key on one photo from SwiftImmich, and stack an uploaded copy over an
original, then look at both in the web and phone apps. That answers most of the open questions in an afternoon.


## What the real-server tests found (2026-09-21, Immich 3.2.0)

Run with `IMMICH_LIVE_SPIKE=1 swift test --filter LiveServerSpikeTests` (skipped otherwise; it uploads tiny
throwaway images named `swiftimmich-spike-*`, then unstacks and trashes them).

- **Notes:** an arbitrary key (`swiftimmich.edit.v1`) is accepted; reads round-trip exactly; a second write overwrites;
  values up to 1 MB were accepted (recipes are ~1 KB); notes survive stacking.
- A missing note answers **HTTP 400 "…not found"**, not 404. `assetMetadata(...)` treats both as "nothing there".
- **Stacks:** `createStack([copy, original])` makes the **first id the cover**; the timeline then shows only the copy with
  a stack size of 2, and the original's own info reports it is stacked.
- Immich refuses to remove a stack's **cover** from its stack (400 "Cannot remove stack's primary asset"). To remove an
  edit we dissolve the stack, re-stack any other members, then trash the copy.
- Identical uploads are recognised by checksum and come back as duplicates of the earlier (even trashed) asset.

## How it works now

- `EditRecipe` (`EditRecipe.swift`): version, `sourceId`, rotation, mirror, crop fractions, all adjustments. Tolerant of
  missing/unknown fields and unknown looks.
- **Save Edit (Keep Original):** renders the JPEG from the original, uploads it, writes the recipe on the copy, copies albums and
  favourite from the original, and stacks `[copy] + existing members + original` so the copy is the cover
  (`ImmichService.publishEditedCopy`). Other photos already in the original's stack stay in it.
- **Re-edit:** opening the Edit panel on a copy loads its recipe and the original's picture; every change starts again from
  the original; saving replaces the copy (old copy trashed). "Replace Original" is hidden while re-editing.
- **Remove Edit…:** `discardEditedCopy` returns to the original.
- "Replace Original" (destructive) still exists for plain photos.

## Not done / ideas

- Recipes only exist for edits made from now on; older "Save as New Photo" copies have none.
- The web and phone apps show the edited copy but not the recipe; only SwiftImmich can reopen it.
- Editing the *original* of a stack (rather than the copy) adds another copy instead of replacing the first.
- Upstream feature request to Immich (native `adjust`/`look` actions) is still worth drafting separately.
