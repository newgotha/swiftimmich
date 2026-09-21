import AVFoundation
import SwiftUI
import ImmichAPI
import CoreImage
import CryptoKit

/// Full-size viewer for one asset within an ordered collection, with prev/next
/// navigation — the "double-click to open" counterpart to the thumbnail grids.
struct PhotoViewerView: View {
    struct AlbumContext: Hashable {
        let id: String
        let name: String
    }

    let service: ImmichService
    /// Called after a successful delete so the grid this viewer was opened from can
    /// drop the asset too, instead of only disappearing from the viewer's own list.
    var onDelete: ((String) -> Void)? = nil
    /// Set when this viewer was opened from one specific album's grid, so "Remove
    /// from Album" can be offered and the grid can drop the asset when it's used.
    var albumContext: AlbumContext? = nil
    /// Which slice of the library this was opened from; the trash gets a reduced set of
    /// actions (restore / delete permanently) and the archive offers Unarchive.
    var filter: TimelineFilter = .none
    /// Set when this is browsing the members of a stack.
    var stackId: String? = nil
    var startSlideshow = false

    @State private var assets: [AssetSummary]
    @State private var currentIndex: Int
    @State private var imageCache: [String: NSImage] = [:]
    @State private var isFavorite = false
    @State private var isTogglingFavorite = false
    @State private var scale: CGFloat = 1
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var isSlideshow = false
    @AppStorage("showFaceOutlines") private var showFaces = false
    @State private var slideshowPaused = false
    @State private var slideshowTask: Task<Void, Never>?
    @State private var slideshowEnteredFullScreen = false
    @AppStorage(Slideshow.secondsKey) private var slideshowSeconds = 4
    @AppStorage(Slideshow.fullScreenKey) private var slideshowFullScreen = true
    @State private var showPermanentDeleteConfirmation = false
    @State private var isChangingState = false
    @State private var slideForward = true
    @State private var albums: [Components.Schemas.AlbumResponseDto] = []
    @State private var showNewAlbumPrompt = false
    @State private var newAlbumName = ""
    @State private var albumActionMessage: String?
    @State private var isApplyingEdit = false
    @State private var editErrorMessage: String?
    @State private var isCropping = false
    @State private var cropRect: CGRect = .zero
    @State private var cropAspect: CropAspect = .free
    @State private var cropPortrait = false
    /// The picture straightened by the Straighten slider; the base for crops and adjustments while it's set.
    @State private var straightenedImage: NSImage?
    @State private var straightenTask: Task<Void, Never>?
    /// Whether the server holds crop / rotate / mirror edits for this photo.
    @State private var isServerEdited = false
    @State private var showRevertConfirmation = false
    // Re-editing an edited copy: the recipe it was made from, and the original's picture to work from.
    @State private var editRecipe: EditRecipe?
    @State private var editBaseImage: NSImage?
    @State private var recipeLoadedFor: String?
    @State private var showRemoveEditConfirmation = false
    // Video tools
    @State private var videoController = VideoPlaybackController()
    @State private var videoSpeed: VideoSpeed = .normal
    @State private var trimSession: TrimSession?
    @State private var videoBusy: String?
    @State private var renderedImageSize: CGSize = .zero
    @State private var showEditOverlay = false
    @State private var showInfoPanel = false
    @State private var isDismissing = false
    /// Where the photo area sits in the window, kept so the swipe-down transition can
    /// draw its stand-in copy of the photo in exactly the same place.
    @State private var imageAreaFrame: CGRect = .zero
    @EnvironmentObject private var viewerTransition: ViewerTransition
    @EnvironmentObject private var membership: AlbumMembership
    @EnvironmentObject private var transfers: TransferCenter
    @EnvironmentObject private var selection: GridSelection

    // Rotate/mirror apply to the preview *instantly*, purely client-side — no
    // network call happens until "Save Changes" is tapped. Crop instead produces an
    // actual locally-cropped NSImage the moment it's confirmed, for the same reason:
    // the user sees the true result immediately rather than waiting on a server
    // round-trip (which, per testing, can lag behind its own 200 OK by several
    // seconds) just to find out whether their edit "took."
    @State private var pendingRotation = 0
    @State private var pendingMirror = false
    @State private var pendingCroppedImage: NSImage?
    @State private var pendingCropPixelRect: (x: Int, y: Int, width: Int, height: Int)?
    // Kept alongside `pendingCropPixelRect` (which is sized for the preview-resolution
    // image sent to Immich's native crop action) so a color-adjusted export can
    // separately recompute the crop against the full-resolution original it downloads.
    @State private var pendingCropFraction: CGRect?
    @State private var pendingAdjustments = ImageAdjustments()
    // The live preview of `pendingAdjustments`, rendered through the same Core Image
    // pipeline the export uses (see `refreshAdjustedPreview`). nil whenever there's
    // nothing to show, in which case the plain base image is displayed.
    @State private var adjustedPreviewImage: NSImage?
    @State private var isRenderingPreview = false
    @State private var previewNeedsRerender = false
    @State private var isAutoEnhancing = false
    @State private var hasUnsavedChanges = false
    @State private var showSaveChoiceDialog = false

    @Environment(\.dismiss) private var dismiss

    init(
        assets: [AssetSummary],
        initialIndex: Int,
        service: ImmichService,
        onDelete: ((String) -> Void)? = nil,
        albumContext: AlbumContext? = nil,
        filter: TimelineFilter = .none,
        stackId: String? = nil,
        startSlideshow: Bool = false
    ) {
        _assets = State(initialValue: assets)
        _currentIndex = State(initialValue: initialIndex)
        _isFavorite = State(initialValue: assets[initialIndex].isFavorite)
        self.service = service
        self.onDelete = onDelete
        self.albumContext = albumContext
        self.filter = filter
        self.stackId = stackId
        self.startSlideshow = startSlideshow
    }

    var body: some View {
        // `assets` can transiently become empty right after removing/deleting the
        // last item, in the window before `dismiss()` finishes popping this view —
        // SwiftUI can still ask for one more body render during that window, and
        // `assets[currentIndex]` on an empty array crashes unconditionally. Guarding
        // here (rather than deeper in) means nothing downstream ever sees a stale index.
        if assets.indices.contains(currentIndex) {
            viewerBody(for: assets[currentIndex])
        } else {
            Color.clear
        }
    }

    private var isBottomBarVisible: Bool {
        isCropping || showEditOverlay || hasUnsavedChanges
    }

    /// The info panel is only what's showing when nothing higher-priority is (see the
    /// bottom stack in `viewerBody`).
    private var isInfoPanelShowing: Bool {
        showInfoPanel && !isCropping && !showEditOverlay
    }

    /// How much room the photo leaves at the bottom so a panel never covers it.
    private var bottomInset: CGFloat {
        if isInfoPanelShowing { return AssetInfoPanel.height + 48 }
        return isBottomBarVisible ? 96 : 0
    }

    @ViewBuilder
    private func viewerBody(for asset: AssetSummary) -> some View {
        ZStack {
            // A ForEach over a single element (keyed by asset id) rather than a plain
            // `.id()` swap — SwiftUI only reliably animates *both* the incoming and
            // outgoing view when it can treat the change as a genuine collection
            // insert/remove; a bare `.id()` change on an always-present view only
            // animated the outgoing side in practice.
            ForEach([asset], id: \.id) { asset in
                content(for: asset)
                    .padding(24)
                    // Shrinks the image to make room for the bottom bar instead of
                    // letting the bar float on top and cover the lower crop handles.
                    .padding(.bottom, bottomInset)
                    .animation(Motion.animation(.easeInOut(duration: 0.25)), value: bottomInset)
                    .transition(.asymmetric(
                        insertion: .move(edge: slideForward ? .trailing : .leading),
                        removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }

            // A two-finger trackpad swipe, not a click-and-drag — the latter made it
            // impossible to drag the crop handles without accidentally paging to the
            // next/previous photo. Placed behind the chevrons/action bars below so
            // those still get first claim on ordinary clicks.
            if scale <= 1 && !isCropping {
                TrackpadSwipeCatcher(
                    onSwipeLeft: showNext,
                    onSwipeRight: showPrevious,
                    onSwipeUp: { showInfo() },
                    onSwipeDown: { swipeDown(asset) }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isCropping && !isSlideshow {
                navigationOverlay
            }

            VStack {
                Spacer()
                if isCropping {
                    cropActionBar(for: asset)
                        .transition(.move(edge: .bottom))
                } else if showEditOverlay {
                    // Takes priority over the plain pending-edits bar below so the
                    // sliders stay visible (with their own Save/Discard row) instead of
                    // being replaced by it the instant a slider makes changes "unsaved."
                    editOverlayPanel(for: asset)
                        .transition(.move(edge: .bottom))
                } else if showInfoPanel {
                    AssetInfoPanel(service: service, assetId: asset.id, canEdit: service.isMine(asset)) {
                        withMotion(.easeInOut(duration: 0.3)) { showInfoPanel = false }
                    }
                    .transition(.move(edge: .bottom))
                } else if hasUnsavedChanges {
                    pendingEditsBar(for: asset)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        // Above the photo (and its zoom/double-tap gestures) so these get their own clicks
        // and hover, centred exactly as the photo is. An overlay, not a ZStack child: sized
        // from the photo's own size, a child fed that size back into the layout and made
        // the photo grow without limit.
        .overlay {
            photoOverlays(for: asset)
                .padding(24)
                .padding(.bottom, bottomInset)
        }
        .toolbar { viewerToolbar(for: asset) }
        .confirmationDialog(
            "Permanently delete this item?",
            isPresented: $showPermanentDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { deleteAssetPermanently(asset) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteAsset(asset) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be moved to Immich's trash, where it can be recovered.")
        }
        .confirmationDialog(
            "Save Edited Photo",
            isPresented: $showSaveChoiceDialog,
            titleVisibility: .visible
        ) {
            Button("Save Edit (Keep Original)") { performColorAdjustedSave(asset, replaceOriginal: false) }
            if editRecipe == nil {
                Button("Replace Original", role: .destructive) { performColorAdjustedSave(asset, replaceOriginal: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save Edit keeps your original and shows the edited copy on top of it, stacked together; you can reopen the edit later. Replace Original moves the original to Immich's trash, where it can still be recovered.")
        }
        .alert("New Album", isPresented: $showNewAlbumPrompt) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") { createAlbumAndAdd(asset: asset) }
                .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .modifier(ViewerAlerts(albumActionMessage: $albumActionMessage, editErrorMessage: $editErrorMessage))
        .task {
            await preload(asset)
        }
        .task {
            albums = (try? await service.fetchAlbums()) ?? []
        }
        .onChange(of: showEditOverlay) { _, isShowing in
            if isShowing { showInfoPanel = false }
        }
        .toolbar(isSlideshow ? .hidden : .automatic, for: .windowToolbar)
        .task { if startSlideshow { beginSlideshow() } }
        .onDisappear { endSlideshow() }
        .background(KeyMonitor { press in handleKey(press, asset: asset) })
        .onAppear { selection.openViewers += 1; selection.hovered = nil }
        .onDisappear { selection.openViewers -= 1; selection.hovered = nil }
        .navigationTitle("Back")
    }

    @ToolbarContentBuilder
    private func viewerToolbar(for asset: AssetSummary) -> some ToolbarContent {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Play Slideshow") { beginSlideshow() }
                    Divider()
                    Picker("Time per photo", selection: $slideshowSeconds) {
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    Toggle("Full screen", isOn: $slideshowFullScreen)
                } label: {
                    Image(systemName: "play.rectangle")
                        .accessibilityLabel("Slideshow")
                }
                .help("Slideshow (S)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFaces.toggle()
                } label: {
                    Image(systemName: showFaces ? "person.crop.rectangle.fill" : "person.crop.rectangle")
                        .accessibilityLabel("Show or hide faces")
                }
                .help("Show or hide faces (P)")
                .disabled(!asset.isImage)
            }
            ToolbarItem(placement: .primaryAction) {
                shareButton(for: asset)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    transfers.download([asset], service: service)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .accessibilityLabel("Download original")
                }
                .help("Download Original…")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if showInfoPanel { withMotion(.easeInOut(duration: 0.3)) { showInfoPanel = false } } else { showInfo() }
                } label: {
                    Image(systemName: showInfoPanel ? "info.circle.fill" : "info.circle")
                        .accessibilityLabel("Info")
                }
                .disabled(isCropping)
            }
            if filter.isTrashed {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        restoreAsset(asset)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(isChangingState)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showPermanentDeleteConfirmation = true
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                    .disabled(isChangingState)
                }
            } else if service.isMine(asset) {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFavorite(asset)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                }
                .disabled(isTogglingFavorite)
            }
            if let stackId {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Remove This Photo from Stack") { removeFromStack(asset, stackId: stackId) }
                        Button("Unstack All", role: .destructive) { unstack(stackId) }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                            .accessibilityLabel("Stack options")
                    }
                    .disabled(isChangingState)
                }
            }
            if filter.albumId == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        toggleArchive(asset)
                    } label: {
                        Image(systemName: filter == .archive ? "tray.and.arrow.up" : "archivebox")
                            .accessibilityLabel(filter == .archive ? "Unarchive" : "Archive")
                    }
                    .help(filter == .archive ? "Unarchive" : "Archive")
                    .disabled(isChangingState)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    rotate()
                } label: {
                    Image(systemName: "rotate.right")
                        .accessibilityLabel("Rotate")
                }
                .disabled(isApplyingEdit || isCropping || pendingCroppedImage != nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    mirror()
                } label: {
                    Image(systemName: "flip.horizontal")
                        .accessibilityLabel("Mirror")
                }
                .disabled(isApplyingEdit || isCropping || pendingCroppedImage != nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleCropMode()
                } label: {
                    Image(systemName: "crop")
                        .accessibilityLabel("Crop")
                }
                .disabled(isApplyingEdit || pendingRotation != 0 || pendingMirror)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withMotion { showEditOverlay.toggle() }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .accessibilityLabel("Edit and enhance")
                }
                .disabled(isCropping)
            }
            albumAndDeleteItems(for: asset)
            }
    }

    /// Album, activity, remove-from-album and delete — split out because a toolbar builder
    /// only accepts ten children at a time.
    @ToolbarContentBuilder
    private func albumAndDeleteItems(for asset: AssetSummary) -> some ToolbarContent {
            albumToolbarItem(for: asset)
            activityToolbarItem(for: asset)
            if let albumContext {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        removeFromAlbum(albumContext, asset: asset)
                    } label: {
                        Image(systemName: "rectangle.stack.badge.minus")
                            .accessibilityLabel("Remove from album")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .accessibilityLabel("Move to trash")
                }
                .disabled(isDeleting)
            }
    }

    /// Comments and likes on this photo, when it's being viewed inside an album that has them on.
    @ToolbarContentBuilder
    private func activityToolbarItem(for asset: AssetSummary) -> some ToolbarContent {
            if let albumContext, albums.first(where: { $0.id == albumContext.id })?.isActivityEnabled == true {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        selection.pendingActivity = ActivityRequest(albumId: albumContext.id, albumName: albumContext.name, assetId: asset.id)
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .accessibilityLabel("Comments and likes")
                    }
                    .help("Comments and likes on this photo")
                }
            }
    }

    @ToolbarContentBuilder
    private func albumToolbarItem(for asset: AssetSummary) -> some ToolbarContent {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(albums.filter { $0.canAddPhotos(userId: service.sharing.currentUserId) }, id: \.id) { album in
                        Button(album.albumName) { addToAlbum(album, asset: asset) }
                    }
                    if !albums.isEmpty {
                        Divider()
                    }
                    Button("New Album…") {
                        newAlbumName = ""
                        showNewAlbumPrompt = true
                    }
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .accessibilityLabel("Add to album")
                }
            }
    }

    @ViewBuilder
    private func photoOverlays(for asset: AssetSummary) -> some View {
        if asset.isImage, !isCropping, !isSlideshow, renderedImageSize.width > 0, renderedImageSize.height > 0 {
            ZStack {
                if let videoId = asset.livePhotoVideoId {
                    LivePhotoLayer(service: service, videoId: videoId, size: renderedImageSize)
                }
                if showFaces, pendingRotation == 0, !pendingMirror, pendingCroppedImage == nil,
                   adjustedPreviewImage == nil, scale <= 1, service.isMine(asset) {
                    FaceOverlayView(service: service, assetId: asset.id, size: renderedImageSize)
                }
            }
        } else if !asset.isImage, !isSlideshow {
            // In this layer, above the full-window swipe catcher, so the controls get their clicks.
            VStack {
                HStack {
                    Spacer()
                    videoTools(for: asset)
                }
                Spacer()
            }
        }
    }

    /// Keyboard shortcuts: ← → page, ↑ info, ↓ / Esc peel back a layer (panel, then viewer),
    /// F favorite, I or ⌘I info, R rotate, Space play/pause a video, Delete to trash.
    private func handleKey(_ press: KeyMonitor.KeyPress, asset: AssetSummary) -> Bool {
        guard !isCropping, !isDismissing else { return false }
        if isSlideshow {
            switch press.keyCode {
            case 53: endSlideshow(); return true
            case 49: slideshowPaused.toggle(); return true
            case 123: showPrevious(); return true
            case 124: showNext(); return true
            default:
                if press.character == "s" { endSlideshow() }
                return true
            }
        }
        if press.isPlain && !press.shift && press.character == "s" {
            beginSlideshow()
            return true
        }
        let inTrash = filter.isTrashed
        // Someone else's photo: browse only.
        let mine = service.isMine(asset)

        if press.isPlain && !press.shift {
            switch press.keyCode {
            case 123: showPrevious(); return true
            case 124: showNext(); return true
            case 126: showInfo(); return true
            case 125, 53: swipeDown(asset); return true
            case 49: return asset.isImage ? false : VideoKeys.togglePlayback()
            case 51, 117:
                guard mine else { return true }
                guard !isDeleting, !isChangingState else { return true }
                if inTrash { showPermanentDeleteConfirmation = true } else { showDeleteConfirmation = true }
                return true
            default: break
            }
            if mine, !inTrash, let stars = Int(press.character), (0...5).contains(stars) {
                Task { await selection.setRating([asset], to: stars == 0 ? nil : stars) }
                return true
            }
            switch press.character {
            case "f" where mine && !inTrash && !isTogglingFavorite:
                toggleFavorite(asset)
                return true
            case "p" where asset.isImage:
                showFaces.toggle()
                return true
            case "i":
                if showInfoPanel { withMotion(.easeInOut(duration: 0.3)) { showInfoPanel = false } } else { showInfo() }
                return true
            case "r" where mine && !inTrash && !(isApplyingEdit || pendingCroppedImage != nil):
                rotate()
                return true
            default: break
            }
        }
        if press.command && !press.option && !press.control {
            if press.character == "i" {
                if showInfoPanel { withMotion(.easeInOut(duration: 0.3)) { showInfoPanel = false } } else { showInfo() }
                return true
            }
            if press.keyCode == 51, mine, !isDeleting, !isChangingState {
                if inTrash { showPermanentDeleteConfirmation = true } else { showDeleteConfirmation = true }
                return true
            }
        }
        return false
    }

    // MARK: - Slideshow

    /// Steps through the photos (skipping videos) every few seconds with the toolbar and
    /// controls hidden, optionally full screen. Esc or S stops it; Space pauses.
    private func beginSlideshow() {
        guard !isSlideshow, !isCropping, assets.contains(where: \.isImage) else { return }
        isSlideshow = true
        slideshowPaused = false
        showInfoPanel = false
        showEditOverlay = false
        if slideshowFullScreen && !Slideshow.isFullScreen {
            slideshowEnteredFullScreen = true
            Slideshow.toggleFullScreen()
        }
        slideshowTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(slideshowSeconds)))
                if Task.isCancelled { return }
                if !slideshowPaused { advanceSlideshow() }
            }
        }
    }

    private func endSlideshow() {
        guard isSlideshow else { return }
        slideshowTask?.cancel()
        slideshowTask = nil
        isSlideshow = false
        if slideshowEnteredFullScreen {
            slideshowEnteredFullScreen = false
            if Slideshow.isFullScreen { Slideshow.toggleFullScreen() }
        }
    }

    /// The next photo after this one, wrapping around, or nothing if there's no other.
    private func advanceSlideshow() {
        let count = assets.count
        for step in 1..<max(count, 1) {
            let index = (currentIndex + step) % count
            if assets[index].isImage {
                navigate(to: index, forward: true)
                return
            }
        }
    }

    /// Swipe up (or the info button): slide the metadata panel up from the bottom.
    private func showInfo() {
        guard !isCropping, !isDismissing else { return }
        withMotion(.easeInOut(duration: 0.3)) {
            showEditOverlay = false
            showInfoPanel = true
        }
    }

    /// Swipe down peels back one layer at a time: an open panel closes first, and only
    /// with nothing open does it leave the viewer — so closing a panel with a swipe
    /// can't also throw you out of the photo.
    private func swipeDown(_ asset: AssetSummary) {
        if showInfoPanel {
            withMotion(.easeInOut(duration: 0.3)) { showInfoPanel = false }
        } else if showEditOverlay {
            withMotion(.easeInOut(duration: 0.3)) { showEditOverlay = false }
        } else {
            dismissViewer(asset)
        }
    }

    /// Slides the photo down while fading it out, then pops back to the grid.
    private func dismissViewer(_ asset: AssetSummary) {
        guard !isDismissing else { return }
        if hasUnsavedChanges {
            // A crop/rotate/mirror is saved the same way swiping to another photo
            // saves it. Colour adjustments and Auto Enhance need an explicit
            // "new photo or replace the original" choice, which a swipe can't make on
            // your behalf — and quietly discarding them would lose work — so the swipe
            // does nothing until you save or discard them yourself.
            guard pendingAdjustments.isIdentity else { return }
            saveNativeEdits(asset)
        }
        isDismissing = true

        // Pop back to the grid straight away and let a stand-in copy of the photo do
        // the sliding and fading on top of it — see `ViewerTransition` for why the
        // two can't overlap any other way.
        viewerTransition.beginDismiss(ghost: ghost(for: asset))
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { dismiss() }
    }

    /// A copy of the photo exactly as it's currently drawn (same place, size,
    /// rotation and mirroring). Videos have no still to copy, so they just cut to the
    /// grid, which still fades in.
    private func ghost(for asset: AssetSummary) -> ViewerTransition.Ghost? {
        guard asset.isImage, let image = displayImage(for: asset), imageAreaFrame.width > 0 else { return nil }
        let pixels = pixelSize(of: image)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let isQuarterTurn = pendingRotation == 90 || pendingRotation == 270
        let aspect = isQuarterTurn ? pixels.height / pixels.width : pixels.width / pixels.height
        let fitted = fitSize(aspect: aspect, in: imageAreaFrame.size)
        return ViewerTransition.Ghost(
            image: image,
            center: CGPoint(x: imageAreaFrame.midX, y: imageAreaFrame.midY),
            size: isQuarterTurn ? CGSize(width: fitted.height, height: fitted.width) : fitted,
            rotation: pendingRotation,
            mirror: pendingMirror
        )
    }

    /// The standard macOS share sheet (AirDrop, Messages, Mail, Notes, Copy, and
    /// whatever else is installed). Shares the version saved on the server, so edits
    /// still pending in the editor (unsaved rotate/crop/adjustments) aren't included.
    @ViewBuilder
    private func shareButton(for asset: AssetSummary) -> some View {
        if asset.isImage {
            ShareLink(
                item: SharedAssetFile(service: service, assetId: asset.id, isImage: true),
                preview: SharePreview(
                    "Photo",
                    image: Image(nsImage: imageCache[asset.id] ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
                )
            )
        } else {
            ShareLink(
                item: SharedAssetFile(service: service, assetId: asset.id, isImage: false),
                preview: SharePreview("Video", image: Image(systemName: "video"))
            )
        }
    }

    /// The image actually shown right now: an auto-enhanced and/or locally-cropped
    /// bake if either is pending, otherwise the plain loaded image — rotation/mirror
    /// are pure display transforms applied on top of whichever of these is current,
    /// not baked into the bitmap.
    private func displayImage(for asset: AssetSummary) -> NSImage? {
        adjustedPreviewImage ?? baseImage(for: asset)
    }

    /// The image before any colour adjustment: a locally-applied crop if one is
    /// pending, otherwise the plain loaded image. Crop and every adjustment render
    /// start from this — never from `displayImage`, which may already have the
    /// current adjustments baked in and would apply them twice.
    private func baseImage(for asset: AssetSummary) -> NSImage? {
        pendingCroppedImage ?? straightenedImage ?? editBaseImage ?? imageCache[asset.id]
    }

    @ViewBuilder
    private func content(for asset: AssetSummary) -> some View {
        if asset.isImage {
            if let image = displayImage(for: asset) {
                GeometryReader { geometry in
                    let pixels = pixelSize(of: image)
                    let isQuarterTurn = pendingRotation == 90 || pendingRotation == 270
                    let effectiveAspect = isQuarterTurn ? pixels.height / pixels.width : pixels.width / pixels.height
                    let fitted = fitSize(aspect: effectiveAspect, in: geometry.size)
                    let preRotationSize = isQuarterTurn
                        ? CGSize(width: fitted.height, height: fitted.width)
                        : fitted

                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: preRotationSize.width, height: preRotationSize.height)
                            // Positive degrees = clockwise, matching "rotate.right"'s
                            // intent and what's sent to Immich's rotate action /
                            // exportBakedJPEG. A prior attempt negated this angle on an
                            // imprecise first bug report; a landmark test (which edge
                            // of the photo ends up on top after one tap) confirmed the
                            // negated version was counter-clockwise, meaning positive
                            // was correct all along.
                            .rotationEffect(.degrees(Double(pendingRotation)))
                            .scaleEffect(x: pendingMirror ? -1 : 1, y: 1)
                            .scaleEffect(isCropping ? 1 : scale)

                        if isCropping {
                            CropOverlayView(imageSize: fitted, cropRect: $cropRect, lockedRatio: lockedCropRatio)
                        }

                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onAppear {
                        renderedImageSize = fitted
                        imageAreaFrame = geometry.frame(in: .global)
                    }
                    .onChange(of: fitted) { _, newValue in renderedImageSize = newValue }
                    .onChange(of: geometry.frame(in: .global)) { _, newValue in imageAreaFrame = newValue }
                }
                .gesture(MagnificationGesture().onChanged { value in
                    guard !isCropping else { return }
                    scale = max(1, value)
                })
                .onTapGesture(count: 2) {
                    guard !isCropping else { return }
                    withMotion { scale = scale > 1 ? 1 : 2.5 }
                }
            } else {
                ProgressView()
            }
        } else {
            VideoPlayerView(request: service.videoPlaybackRequest(assetId: asset.id), controller: videoController)
        }
    }

    // MARK: - Video tools

    private func videoTools(for asset: AssetSummary) -> some View {
        HStack(spacing: 10) {
            if let videoBusy {
                ProgressView().controlSize(.small)
                Text(videoBusy).font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                ForEach(VideoSpeed.allCases) { speed in
                    Button {
                        videoSpeed = speed
                        videoController.speed = speed
                    } label: {
                        if videoSpeed == speed { Label(speed.title, systemImage: "checkmark") } else { Text(speed.title) }
                    }
                }
            } label: {
                Label(videoSpeed == .normal ? "Speed" : videoSpeed.title, systemImage: "speedometer")
            }
            .fixedSize()
            .help("Playback speed")
            if service.isMine(asset), !filter.isTrashed {
                Button {
                    saveFrame(of: asset)
                } label: {
                    Label("Save Frame", systemImage: "camera.viewfinder")
                }
                .help("Save the picture on screen as a new photo")
                .disabled(videoBusy != nil)
                Button {
                    prepareTrim(asset)
                } label: {
                    Label("Trim…", systemImage: "scissors")
                }
                .help("Cut the start and end off this video")
                .disabled(videoBusy != nil)
            }
        }
        .buttonStyle(ToolbarPillStyle())
        .font(.callout)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(12)
        .sheet(item: $trimSession) { session in
            VideoTrimView(
                session: session,
                save: { range, mode, stage in try await saveTrimmed(asset, session: session, range: range, mode: mode, stage: stage) },
                close: { trimSession = nil }
            )
        }
    }

    /// Downloads the original so it can be cut and previewed exactly.
    private func prepareTrim(_ asset: AssetSummary) {
        videoController.player?.pause()
        videoBusy = "Getting the video…"
        Task {
            defer { videoBusy = nil }
            do {
                let info = try await service.fetchAssetInfo(assetId: asset.id)
                let file = try await service.downloadForSharing(assetId: asset.id, isImage: false)
                let duration = try await AVURLAsset(url: file).load(.duration).seconds
                guard duration.isFinite, duration > TrimRange.minimumLength else {
                    editErrorMessage = "This video is too short to trim."
                    return
                }
                trimSession = TrimSession(fileURL: file, duration: duration, title: info.originalFileName)
            } catch {
                editErrorMessage = "Couldn't get the video to trim: \(error.localizedDescription)"
            }
        }
    }

    private func saveTrimmed(_ asset: AssetSummary, session: TrimSession, range: TrimRange, mode: VideoExporter.Mode, stage: @escaping @Sendable (TrimStage) -> Void) async throws {
        let cut = try await VideoExporter.export(source: session.fileURL, range: range, mode: mode) { stage(.cutting($0)) }
        defer { try? FileManager.default.removeItem(at: cut.deletingLastPathComponent()) }
        stage(.uploading)
        let info = try await service.fetchAssetInfo(assetId: asset.id)
        let checksum = try TransferCenter.sha1(of: cut)
        let baseName = (info.originalFileName as NSString).deletingPathExtension
        let result = try await service.uploadAsset(
            fileURL: cut, filename: "\(baseName)-trimmed.\(cut.pathExtension)",
            createdAt: info.fileCreatedAt, modifiedAt: Date(), checksum: checksum
        )
        let newId: String
        switch result {
        case .created(let id), .duplicate(let id): newId = id
        }
        NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
        insertAndShowNewAsset(newId, near: asset, seedImage: nil, isImage: false)
        selection.showToast("Saved the trimmed video. The original is untouched.")
    }

    /// Saves the frame on screen as a new photo.
    private func saveFrame(of asset: AssetSummary) {
        guard let videoAsset = videoController.currentAsset else { return }
        let seconds = videoController.currentSeconds
        videoBusy = "Saving frame…"
        Task {
            defer { videoBusy = nil }
            do {
                let picture = try await VideoFrames.frame(of: videoAsset, at: seconds)
                guard let jpeg = VideoFrames.jpegData(from: picture) else {
                    editErrorMessage = "Couldn't turn that frame into a photo."
                    return
                }
                let info = try await service.fetchAssetInfo(assetId: asset.id)
                let baseName = (info.originalFileName as NSString).deletingPathExtension
                let checksum = Insecure.SHA1.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
                _ = try await service.uploadAsset(
                    data: jpeg,
                    filename: "\(baseName)-frame-\(VideoClock.text(seconds).replacingOccurrences(of: ":", with: "m").replacingOccurrences(of: ".", with: "s")).jpg",
                    createdAt: info.fileCreatedAt.addingTimeInterval(seconds),
                    modifiedAt: Date(),
                    checksum: checksum
                )
                NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
                selection.showToast("Saved this frame as a new photo.")
            } catch {
                editErrorMessage = "Couldn't save that frame: \(error.localizedDescription)"
            }
        }
    }

    private func fitSize(aspect: CGFloat, in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0, aspect > 0 else { return .zero }
        let containerAspect = container.width / container.height
        if aspect > containerAspect {
            return CGSize(width: container.width, height: container.width / aspect)
        } else {
            return CGSize(width: container.height * aspect, height: container.height)
        }
    }

    private func cropActionBar(for asset: AssetSummary) -> some View {
        HStack {
            Button("Cancel") { isCropping = false }
                .buttonStyle(.bordered)
            Spacer()
            Menu {
                ForEach(CropAspect.allCases) { aspect in
                    Button {
                        chooseCropAspect(aspect)
                    } label: {
                        if cropAspect == aspect { Label(aspect.title, systemImage: "checkmark") } else { Text(aspect.title) }
                    }
                }
            } label: {
                Label(cropAspect.title, systemImage: "aspectratio")
            }
            .fixedSize()
            Button {
                flipCropAspect()
            } label: {
                Image(systemName: "rectangle.portrait.rotate")
                    .accessibilityLabel("Switch between portrait and landscape")
            }
            .buttonStyle(.bordered)
            .disabled(!cropAspect.canFlip)
            .help("Switch between portrait and landscape")
            Spacer()
            Button("Apply Crop") { confirmCrop(asset) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding()
    }

    private func pendingEditsBar(for asset: AssetSummary) -> some View {
        HStack {
            Button("Discard") { discardPendingEdits() }
                .buttonStyle(.bordered)
                .disabled(isApplyingEdit)
            Spacer()
            if isApplyingEdit {
                ProgressView().controlSize(.small)
            }
            Button("Save Changes") { saveEdits(asset) }
                .buttonStyle(.borderedProminent)
                .disabled(isApplyingEdit)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding()
    }

    private func editOverlayPanel(for asset: AssetSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit")
                    .font(.headline)
                Spacer()
                Button {
                    withMotion { showEditOverlay = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button {
                    applyAutoEnhance(asset)
                } label: {
                    if isAutoEnhancing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(pendingAdjustments.autoEnhance == nil ? "Auto Enhance" : "Re-run", systemImage: "wand.and.rays")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isAutoEnhancing || isCropping)
                if pendingAdjustments.autoEnhance != nil {
                    Slider(value: Binding(
                        get: { pendingAdjustments.autoEnhance?.intensity ?? 1 },
                        set: { newValue in adjustmentChanged(asset) { $0.autoEnhance?.intensity = newValue } }
                    ), in: 0...2)
                } else {
                    Spacer()
                }
            }
            Divider()
            ScrollView {
                EditControls(
                    adjustments: pendingAdjustments,
                    baseImage: pendingCroppedImage ?? imageCache[asset.id],
                    cropIsPending: pendingCroppedImage != nil,
                    change: { mutate in adjustmentChanged(asset, mutate) },
                    changeStraighten: { straightenChanged(asset, $0) }
                )
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 300)
            Text("Immich can't store looks or colour changes on the original file, so saving asks whether to make a new photo or replace the original.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recipe = editRecipe {
                Text("This is an edited copy. Changes start again from your original, and saving replaces this copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove Edit…") { showRemoveEditConfirmation = true }
                    .buttonStyle(.bordered)
                    .disabled(isApplyingEdit)
                    .help("Go back to the original photo (edit from \(recipe.sourceId.prefix(8)))")
            }
            if isServerEdited {
                Button("Revert to Original…") { showRevertConfirmation = true }
                    .buttonStyle(.bordered)
                    .disabled(isApplyingEdit)
                    .help("Removes the crop, rotation and mirroring saved for this photo")
            }
            HStack {
                Button("Discard") { discardPendingEdits() }
                    .buttonStyle(.bordered)
                    .disabled(isApplyingEdit || !hasUnsavedChanges)
                Spacer()
                if isApplyingEdit {
                    ProgressView().controlSize(.small)
                }
                Button("Save Changes") { saveEdits(asset) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplyingEdit || !hasUnsavedChanges)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        .task(id: asset.id) {
            isServerEdited = (try? await service.fetchAssetInfo(assetId: asset.id))?.isEdited == true
            await loadRecipe(for: asset)
        }
        .confirmationDialog("Remove this edit?", isPresented: $showRemoveEditConfirmation) {
            Button("Remove Edit", role: .destructive) { removeEditedCopy(asset) }
        } message: {
            Text("The edited copy goes to Immich's trash, and your original is shown again. The original is untouched.")
        }
        .confirmationDialog("Revert to the original?", isPresented: $showRevertConfirmation) {
            Button("Revert to Original", role: .destructive) { revertToOriginal(asset) }
        } message: {
            Text("This removes the crop, rotation and mirroring saved for this photo on your server. The original file isn't touched.")
        }
    }

    private var navigationOverlay: some View {
        HStack {
            navigationButton(systemImage: "chevron.left", action: showPrevious)
                .opacity(currentIndex == 0 ? 0 : 1)
                .disabled(currentIndex == 0)

            Spacer()

            navigationButton(systemImage: "chevron.right", action: showNext)
                .opacity(currentIndex == assets.count - 1 ? 0 : 1)
                .disabled(currentIndex == assets.count - 1)
        }
        .padding()
    }

    private func navigationButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func showPrevious() {
        guard currentIndex > 0 else { return }
        navigate(to: currentIndex - 1, forward: false)
    }

    private func showNext() {
        guard currentIndex < assets.count - 1 else { return }
        navigate(to: currentIndex + 1, forward: true)
    }

    /// Loads the target photo's image fully *before* starting the slide animation,
    /// so both the incoming and outgoing views show finished content throughout the
    /// transition — loading it after the index changes let the new image "pop in"
    /// mid-slide instead of sliding in already-formed.
    private func navigate(to index: Int, forward: Bool) {
        guard assets.indices.contains(index) else { return }
        let target = assets[index]
        slideForward = forward
        isFavorite = target.isFavorite
        // Swiping away used to silently discard any pending crop/rotate/mirror —
        // resetPendingEditState() below cleared it with no save and no warning, which
        // looked like (and was) losing the edit. Fire the same non-destructive save
        // the "Save Changes" button uses before discarding the local preview state;
        // it runs in the background and doesn't block the slide to the next photo.
        // Color adjustments still require the explicit button, since persisting those
        // needs the New Photo / Replace Original choice, which shouldn't fire from a
        // swipe gesture.
        if hasUnsavedChanges && pendingAdjustments.isIdentity {
            saveNativeEdits(assets[currentIndex])
        }
        resetPendingEditState()
        Task {
            await preload(target)
            withMotion(.easeInOut(duration: 0.3)) {
                currentIndex = index
                scale = 1
            }
        }
    }

    private func resetPendingEditState() {
        pendingRotation = 0
        pendingMirror = false
        pendingCroppedImage = nil
        pendingCropPixelRect = nil
        pendingCropFraction = nil
        pendingAdjustments = .identity
        straightenTask?.cancel()
        straightenedImage = nil
        editBaseImage = nil
        editRecipe = nil
        recipeLoadedFor = nil
        adjustedPreviewImage = nil
        previewNeedsRerender = false
        hasUnsavedChanges = false
        isCropping = false
    }

    private func preload(_ target: AssetSummary) async {
        guard target.isImage, imageCache[target.id] == nil else { return }
        if let loaded = await ThumbnailLoader.shared.image(
            for: "preview-\(target.id)",
            request: service.previewRequest(assetId: target.id)
        ) {
            imageCache[target.id] = loaded
        }
    }

    private func toggleCropMode() {
        if !isCropping {
            // Fractional (0...1) bounds — trivially "the whole image" regardless of
            // the image's actual on-screen size, so it's correct even if that size
            // hasn't finished settling yet (e.g. mid-shrink for the bottom bar).
            cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            cropAspect = .free
            cropPortrait = false
            scale = 1
        }
        withMotion { isCropping.toggle() }
    }

    private func rotate() {
        // Immich's rotate angle is absolute (0/90/180/270), not a delta.
        withMotion(.easeInOut(duration: 0.3)) {
            pendingRotation = (pendingRotation + 90) % 360
        }
        hasUnsavedChanges = true
    }

    private func mirror() {
        withMotion(.easeInOut(duration: 0.3)) {
            pendingMirror.toggle()
        }
        hasUnsavedChanges = true
    }

    /// Confirms the dragged crop rectangle: crops the image locally (for an instant,
    /// exact preview) and records the pixel rect to send when the user saves.
    /// `cropRect` is fractional, so converting straight to the source's true pixel
    /// dimensions needs no on-screen size at all — sidestepping any dependency on
    /// `renderedImageSize` having already settled to its current value.
    private func confirmCrop(_ asset: AssetSummary) {
        // The crop was drawn over the straightened picture, so make sure that's what it's cut from.
        makeStraightenedBase(for: asset)
        guard let source = baseImage(for: asset) else {
            isCropping = false
            return
        }
        let pixels = pixelSize(of: source)

        let x = Int((cropRect.minX * pixels.width).rounded())
        let y = Int((cropRect.minY * pixels.height).rounded())
        let width = Int((cropRect.width * pixels.width).rounded())
        let height = Int((cropRect.height * pixels.height).rounded())
        isCropping = false
        guard width > 0, height > 0, let cropped = croppedImage(source, pixelRect: CGRect(x: x, y: y, width: width, height: height)) else {
            return
        }

        pendingCroppedImage = cropped
        pendingCropPixelRect = (x: x, y: y, width: width, height: height)
        pendingCropFraction = cropRect
        hasUnsavedChanges = true
        // The base just changed shape, so any adjusted preview of the old base is stale.
        adjustedPreviewImage = nil
        refreshAdjustedPreview(for: asset)
    }

    private func croppedImage(_ image: NSImage, pixelRect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgImage.cropping(to: pixelRect)
        else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    /// Runs Core Image's own scene analysis (exposure, shadows/highlights, color
    /// balance, etc. — whatever `autoAdjustmentFilters()` decides the photo needs) and
    /// bakes the result into a real preview image immediately, the same way crop
    /// does. Always computed fresh from the crop-baked-or-original base (not from
    /// `displayImage`, which may already include a previous Auto Enhance pass) so
    /// tapping it again re-analyzes cleanly instead of compounding.
    /// Runs Core Image's scene analysis once per tap ("Re-run" analyzes again from
    /// scratch), off the main thread. The intensity slider then only rescales the
    /// stored amounts (see `ImageAdjustments.AutoEnhance`) rather than re-analyzing.
    private func applyAutoEnhance(_ asset: AssetSummary) {
        guard let base = baseImage(for: asset) else { return }
        isAutoEnhancing = true
        Task {
            let analysis = await Task.detached(priority: .userInitiated) {
                ImageAdjustments.analyzeAutoEnhance(base)
            }.value
            isAutoEnhancing = false
            guard let analysis else { return }
            pendingAdjustments.autoEnhance = analysis
            hasUnsavedChanges = true
            refreshAdjustedPreview(for: asset)
        }
    }

    private var displayedAspect: CGFloat {
        renderedImageSize.height > 0 ? renderedImageSize.width / renderedImageSize.height : 1
    }

    /// The crop rectangle's own width / height ratio while a fixed shape is chosen.
    private var lockedCropRatio: CGFloat? {
        guard let pixel = cropAspect.pixelRatio(imageAspect: displayedAspect, portrait: cropPortrait) else { return nil }
        return CropGeometry.fractionalRatio(pixelRatio: pixel, imageAspect: displayedAspect)
    }

    private func chooseCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        // Start in the picture's own orientation; the flip button switches it.
        cropPortrait = displayedAspect < 1
        if let ratio = lockedCropRatio { cropRect = CropGeometry.fit(fractionalRatio: ratio) }
    }

    private func flipCropAspect() {
        cropPortrait.toggle()
        if let ratio = lockedCropRatio { cropRect = CropGeometry.fit(fractionalRatio: ratio) }
    }

    /// If this photo is an edited copy, loads the recipe it was made from and the original's picture, so
    /// the sliders open where they were left and every change starts again from the original.
    private func loadRecipe(for asset: AssetSummary) async {
        guard asset.isImage, service.isMine(asset), recipeLoadedFor != asset.id else { return }
        recipeLoadedFor = asset.id
        guard !hasUnsavedChanges,
              let recipe = try? await service.assetMetadata(EditRecipe.self, key: EditRecipe.key, assetId: asset.id) else { return }
        guard let source = await ThumbnailLoader.shared.image(for: "preview-\(recipe.sourceId)", request: service.previewRequest(assetId: recipe.sourceId)) else { return }
        // Never overwrite work in progress, or a different photo's state.
        guard !hasUnsavedChanges, assets.indices.contains(currentIndex), assets[currentIndex].id == asset.id else { return }

        editRecipe = recipe
        editBaseImage = source
        pendingRotation = recipe.rotation
        pendingMirror = recipe.mirror
        pendingAdjustments = recipe.adjustments
        makeStraightenedBase(for: asset)
        if let crop = recipe.crop {
            cropRect = crop.rect
            confirmCrop(asset)
        }
        hasUnsavedChanges = false
        refreshAdjustedPreview(for: asset)
    }

    /// Puts the original back in place of an edited copy.
    private func removeEditedCopy(_ asset: AssetSummary) {
        guard let recipe = editRecipe else { return }
        isApplyingEdit = true
        Task {
            defer { isApplyingEdit = false }
            do {
                try await service.discardEditedCopy(copyId: asset.id)
                await ThumbnailLoader.shared.invalidate(assetId: asset.id)
                resetPendingEditState()
                NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
                replaceAssetLocally(oldId: asset.id, newId: recipe.sourceId, seedImage: nil)
                selection.showToast("Edit removed. Your original is back.")
            } catch {
                editErrorMessage = "Couldn't remove the edit: \(error.localizedDescription)"
            }
        }
    }

    /// The Straighten slider. Crops are drawn over the straightened picture, so changing the angle
    /// starts any crop over; the straightened picture becomes the base everything else renders from.
    private func straightenChanged(_ asset: AssetSummary, _ degrees: Double) {
        if pendingCroppedImage != nil {
            pendingCroppedImage = nil
            pendingCropPixelRect = nil
            pendingCropFraction = nil
        }
        let angle = abs(degrees) < 0.05 ? 0 : degrees
        pendingAdjustments.straighten = angle
        hasUnsavedChanges = true

        // While dragging, each tick is one small render straight from the original (straighten and
        // any colour changes together), coalesced like every other slider. The full straightened
        // picture that crops are drawn over is only made once the slider has paused.
        straightenTask?.cancel()
        straightenedImage = nil
        refreshAdjustedPreview(for: asset)
        guard angle != 0 else { return }
        straightenTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            makeStraightenedBase(for: asset)
        }
    }

    /// The straightened picture that a crop is drawn over and that later adjustments start from.
    private func makeStraightenedBase(for asset: AssetSummary) {
        let angle = pendingAdjustments.straighten
        guard angle != 0, pendingCroppedImage == nil, straightenedImage == nil, assets.indices.contains(currentIndex),
              assets[currentIndex].id == asset.id, let source = editBaseImage ?? imageCache[asset.id] else { return }
        straightenedImage = ImageAdjustments.renderStraightened(of: source, degrees: angle, maxDimension: 1600)
    }

    /// Removes the crop / rotate / mirror edits the server holds for this photo.
    private func revertToOriginal(_ asset: AssetSummary) {
        isApplyingEdit = true
        Task {
            defer { isApplyingEdit = false }
            do {
                try await service.applyEdits(assetId: asset.id, actions: [])
                isServerEdited = false
                resetPendingEditState()
                // The server rebuilds its preview in the background, so look again shortly after too.
                for pause in [0.0, 4.0] {
                    if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
                    await ThumbnailLoader.shared.invalidate(assetId: asset.id)
                    imageCache[asset.id] = nil
                    NotificationCenter.default.post(name: .assetEdited, object: asset.id)
                    await preload(asset)
                }
            } catch {
                editErrorMessage = "Couldn't revert: \(error)"
            }
        }
    }

    /// Every slider goes through here: apply the change, mark the edit unsaved, and
    /// re-render the preview.
    private func adjustmentChanged(_ asset: AssetSummary, _ mutate: (inout ImageAdjustments) -> Void) {
        mutate(&pendingAdjustments)
        hasUnsavedChanges = true
        refreshAdjustedPreview(for: asset)
    }

    /// Renders `pendingAdjustments` over the base image through the same pipeline
    /// the export uses, so what the sliders show is what gets saved.
    ///
    /// Rendering happens off the main thread and is coalesced: while one render is
    /// in flight, further slider movement just flags that a newer one is needed, and
    /// only the latest values get rendered next. Doing this synchronously on the main
    /// thread for every drag tick (the first version) made the sliders visibly laggy.
    /// The short sleep caps how often the whole viewer is asked to redraw.
    private func refreshAdjustedPreview(for asset: AssetSummary) {
        guard !pendingAdjustments.isIdentity else {
            adjustedPreviewImage = nil
            previewNeedsRerender = false
            return
        }
        previewNeedsRerender = true
        guard !isRenderingPreview else { return }
        isRenderingPreview = true
        Task {
            while previewNeedsRerender {
                previewNeedsRerender = false
                guard let base = baseImage(for: asset) else { break }
                let adjustments = pendingAdjustments
                // Straighten here unless the base picture has already been straightened (or cropped from a straightened one).
                let needsStraighten = pendingCroppedImage == nil && straightenedImage == nil
                let rendered = await Task.detached(priority: .userInitiated) {
                    ImageAdjustments.renderPreview(of: base, adjustments: adjustments, includeStraighten: needsStraighten)
                }.value
                // Only publish if the user is still looking at this photo with
                // adjustments still pending — they may have swiped away or discarded
                // while this render was running.
                if assets.indices.contains(currentIndex), assets[currentIndex].id == asset.id, !pendingAdjustments.isIdentity {
                    adjustedPreviewImage = rendered
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
            isRenderingPreview = false
        }
    }


    private func discardPendingEdits() {
        withMotion {
            pendingRotation = 0
            pendingMirror = false
            pendingCroppedImage = nil
            pendingCropPixelRect = nil
            pendingCropFraction = nil
            pendingAdjustments = .identity
            straightenTask?.cancel()
            straightenedImage = nil
            editBaseImage = nil
            editRecipe = nil
            recipeLoadedFor = nil
            adjustedPreviewImage = nil
            previewNeedsRerender = false
            hasUnsavedChanges = false
        }
    }

    /// Routes to whichever save path the pending edits actually support: Immich's
    /// native non-destructive `/edits` endpoint for plain crop/rotate/mirror, or the
    /// bake-and-choose flow when a color adjustment (which Immich can't store at all)
    /// is also pending.
    private func saveEdits(_ asset: AssetSummary) {
        // An edited copy is always re-made from its original, never edited in place on the server.
        guard pendingAdjustments.isIdentity, editRecipe == nil else {
            showSaveChoiceDialog = true
            return
        }
        saveNativeEdits(asset)
    }

    /// Sends the complete combined edit state in one call (Immich replaces the whole
    /// edit state per call rather than accumulating — confirmed by testing that
    /// applying mirror after rotate silently discarded the rotation). The local
    /// preview already shows the correct result while pendingRotation/pendingMirror/
    /// pendingCroppedImage are still set, but once the user navigates away and
    /// `resetPendingEditState()` clears that overlay, whatever's sitting in
    /// `imageCache[asset.id]` is what shows — and until now that was always the
    /// original, never-updated bitmap, making a *successfully saved* edit look like it
    /// had reverted the moment you left the photo. Baking the rotation/mirror into a
    /// real image and replacing the cache entry with it fixes that without needing a
    /// server round-trip (which would hit the same async-render lag this session's
    /// instant-local-preview redesign was built to avoid in the first place).
    private func saveNativeEdits(_ asset: AssetSummary) {
        var actions: [ImmichService.EditAction] = []
        if pendingRotation != 0 {
            actions.append(.rotate(degrees: pendingRotation))
        }
        if pendingMirror {
            actions.append(.mirror(axis: .horizontal))
        }
        if let crop = pendingCropPixelRect {
            actions.append(.crop(x: crop.x, y: crop.y, width: crop.width, height: crop.height))
        }
        guard !actions.isEmpty else {
            hasUnsavedChanges = false
            return
        }

        // Captured synchronously now, not re-read after the `await` below — if this
        // save was triggered by swiping away (see `navigate()`), resetPendingEditState()
        // runs right after this call returns and would otherwise zero these out before
        // the network call even completes.
        let rotation = pendingRotation
        let mirror = pendingMirror
        let baseImage = pendingCroppedImage ?? imageCache[asset.id]

        isApplyingEdit = true
        Task {
            defer { isApplyingEdit = false }
            do {
                try await service.applyEdits(assetId: asset.id, actions: actions)
                isServerEdited = true
                let baked = baseImage.flatMap { bakedImage(from: $0, rotation: rotation, mirror: mirror) }
                if let baked {
                    imageCache[asset.id] = baked
                    // Seeded with the locally-baked bytes rather than just invalidated —
                    // Immich regenerates a saved edit's actual thumbnail/preview files
                    // as a background job that lags behind this call's own success, so
                    // a grid cell refetching *right now* could still get served the
                    // pre-edit render. This is exactly why the viewer itself never
                    // waits on a re-fetch either; the grid shouldn't have to.
                    await ThumbnailLoader.shared.seed(assetId: asset.id, image: baked)
                } else {
                    await ThumbnailLoader.shared.invalidate(assetId: asset.id)
                }
                // Tells any grid cell for this asset that's already loaded (this
                // viewer was very likely pushed from one) to refetch — which will now
                // hit the freshly-seeded cache above instead of the network.
                NotificationCenter.default.post(name: .assetEdited, object: asset.id)
                // Only clear the live rotate/mirror/crop overlay if we're still
                // looking at the photo that was just saved. If this save was
                // triggered by swiping away (see `navigate()`), the user may already
                // be editing a *different* photo by the time this completes — wiping
                // pendingRotation/etc. here unconditionally would discard THEIR
                // in-progress edit, and applying this photo's now-baked rotation
                // *on top of* its still-active pendingRotation is exactly what caused
                // the "rotates once more, then un-rotates on swipe" glitch.
                if assets.indices.contains(currentIndex), assets[currentIndex].id == asset.id {
                    pendingRotation = 0
                    pendingMirror = false
                    pendingCroppedImage = nil
                    pendingCropPixelRect = nil
                    pendingCropFraction = nil
                    hasUnsavedChanges = false
                }
            } catch {
                editErrorMessage = "Couldn't save changes: \(error)"
            }
        }
    }

    /// Bakes the pending crop/rotate/mirror/color-adjustment state into a real JPEG
    /// exported from the full-resolution original, then either uploads it as a
    /// standalone new photo or uses it to "replace" the original: the new file is
    /// uploaded, its albums/favorite/stack are copied over from the original via
    /// `copyAssetMetadata`, and the original is moved to Immich's trash — recoverable,
    /// not a permanent delete, since Immich has no way to swap a file in place.
    private func performColorAdjustedSave(_ asset: AssetSummary, replaceOriginal: Bool) {
        // Snapshotted now, before anything slow happens — see `ExportRecipe`.
        let recipe = ExportRecipe(
            rotation: pendingRotation,
            mirror: pendingMirror,
            cropFraction: pendingCropFraction,
            adjustments: pendingAdjustments,
            previewMean: baseImage(for: asset)
                .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                .flatMap { ImageRenderer.meanRGB(CIImage(cgImage: $0)) }
        )
        // Editing an edited copy starts over from its original, and replaces the copy.
        let sourceId = editRecipe?.sourceId ?? asset.id
        let previousCopyId = editRecipe == nil ? nil : asset.id
        isApplyingEdit = true
        Task {
            defer { isApplyingEdit = false }
            do {
                let (data, _) = try await URLSession.shared.data(
                    for: service.originalFileRequest(assetId: sourceId, edited: false)
                )
                let jpegData = await Task.detached(priority: .userInitiated) {
                    recipe.render(originalData: data)
                }.value
                guard let jpegData else {
                    editErrorMessage = "Couldn't render your edits."
                    return
                }

                let info = try await service.fetchAssetInfo(assetId: sourceId)
                let baseName = (info.originalFileName as NSString).deletingPathExtension
                let checksum = Insecure.SHA1.hash(data: jpegData).map { String(format: "%02x", $0) }.joined()
                let result = try await service.uploadAsset(
                    data: jpegData,
                    filename: "\(baseName)-edited.jpg",
                    createdAt: info.fileCreatedAt,
                    modifiedAt: Date(),
                    checksum: checksum
                )
                let newAssetId: String
                switch result {
                case .created(let assetId), .duplicate(let assetId):
                    newAssetId = assetId
                }
                // Seed the local cache with the exact bytes just uploaded instead of
                // fetching Immich's own rendered preview — that's generated
                // asynchronously, and waiting on it is exactly the stale/spinner race
                // this session's crop/rotate/mirror redesign already moved away from.
                let bakedImage = NSImage(data: jpegData)

                if replaceOriginal {
                    try await service.copyAssetMetadata(sourceId: asset.id, targetId: newAssetId)
                    try await service.trashAsset(assetId: asset.id)
                    await ThumbnailLoader.shared.invalidate(assetId: asset.id)
                    discardPendingEdits()
                    replaceAssetLocally(oldId: asset.id, newId: newAssetId, seedImage: bakedImage)
                } else {
                    try await service.publishEditedCopy(
                        newCopyId: newAssetId, originalId: sourceId, replacing: previousCopyId,
                        recipe: EditRecipe(recipe, sourceId: sourceId)
                    )
                    await ThumbnailLoader.shared.invalidate(assetId: newAssetId)
                    NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
                    discardPendingEdits()
                    if previousCopyId != nil {
                        replaceAssetLocally(oldId: asset.id, newId: newAssetId, seedImage: bakedImage)
                    } else {
                        insertAndShowNewAsset(newAssetId, near: asset, seedImage: bakedImage)
                    }
                    selection.showToast("Saved. Your original is kept underneath.")
                }
            } catch {
                editErrorMessage = "Couldn't save your edits: \(error)"
            }
        }
    }

    /// Bakes a rotate/mirror into a real NSImage — used to refresh `imageCache` after
    /// a native edit saves (see `saveNativeEdits`), since the pending rotation/mirror
    /// are otherwise pure display transforms never applied to the cached bitmap.
    private func bakedImage(from base: NSImage, rotation: Int, mirror: Bool) -> NSImage? {
        guard rotation != 0 || mirror else { return base }
        guard let cgImage = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let oriented = CIImage(cgImage: cgImage).oriented(ImageRenderer.orientation(forRotation: rotation, mirror: mirror))
        guard let rendered = ImageRenderer.context.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: ImageRenderer.sRGB) else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
    }

    /// Swaps the replaced asset's id into the viewer's local list in place (preserving
    /// position, favorite state, and aspect ratio) and tells the grid this viewer was
    /// opened from to drop the old id, the same callback used for delete.
    private func replaceAssetLocally(oldId: String, newId: String, seedImage: NSImage?) {
        onDelete?(oldId)
        guard let index = assets.firstIndex(where: { $0.id == oldId }) else { return }
        let old = assets[index]
        let updated = AssetSummary(id: newId, isFavorite: old.isFavorite, isImage: old.isImage, ratio: old.ratio)
        assets[index] = updated
        imageCache[oldId] = nil
        if let seedImage {
            imageCache[newId] = seedImage
        } else {
            Task { await preload(updated) }
        }
        isFavorite = updated.isFavorite
    }

    /// Inserts the newly uploaded "Save as New Photo" asset right after the original
    /// in the viewer's local list and navigates to it — staying on the original after
    /// a save left no way to actually see what was just saved.
    private func insertAndShowNewAsset(_ newId: String, near asset: AssetSummary, seedImage: NSImage?, isImage: Bool = true) {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let insertIndex = index + 1
        let newAsset = AssetSummary(id: newId, isFavorite: false, isImage: isImage, ratio: asset.ratio)
        assets.insert(newAsset, at: insertIndex)
        if let seedImage {
            imageCache[newId] = seedImage
        }
        navigate(to: insertIndex, forward: true)
    }

    private func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private func toggleFavorite(_ asset: AssetSummary) {
        let targetId = asset.id
        let newValue = !isFavorite
        isFavorite = newValue
        isTogglingFavorite = true
        Task {
            defer { isTogglingFavorite = false }
            do {
                try await service.setFavorite(assetId: targetId, isFavorite: newValue)
                if let index = assets.firstIndex(where: { $0.id == targetId }) { assets[index].isFavorite = newValue }
                NotificationCenter.default.post(name: .assetsFavoriteChanged, object: FavoriteChange(ids: [targetId], value: newValue))
            } catch {
                isFavorite = !newValue
            }
        }
    }

    private func addToAlbum(_ album: Components.Schemas.AlbumResponseDto, asset: AssetSummary) {
        let targetId = asset.id
        Task {
            do {
                try await service.addAsset(targetId, toAlbum: album.id)
                membership.add([targetId], to: .init(id: album.id, name: album.albumName))
                albumActionMessage = "Added to “\(album.albumName)”."
            } catch {
                albumActionMessage = "Couldn't add to “\(album.albumName)”: \(error)"
            }
        }
    }

    private func createAlbumAndAdd(asset: AssetSummary) {
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let targetId = asset.id
        Task {
            do {
                let album = try await service.createAlbum(name: name, initialAssetId: targetId)
                albums.insert(album, at: 0)
                membership.add([targetId], to: .init(id: album.id, name: album.albumName))
                albumActionMessage = "Added to new album “\(album.albumName)”."
            } catch {
                albumActionMessage = "Couldn't create album: \(error)"
            }
        }
    }

    /// Removes the asset at `removedId` from the local list and, if it was the last
    /// one, dismisses. Shared by delete and remove-from-album, which only differ in
    /// which network call runs first.
    private func removeLocally(assetId removedId: String) {
        onDelete?(removedId)
        guard let removedIndex = assets.firstIndex(where: { $0.id == removedId }) else { return }
        assets.remove(at: removedIndex)
        guard !assets.isEmpty else {
            dismiss()
            return
        }
        if currentIndex >= assets.count {
            currentIndex = assets.count - 1
        }
        // Whichever asset now lands on currentIndex needs its own image loaded —
        // nothing else triggers that after a removal (unlike navigate(), which always
        // preloads before switching), so without this it's stuck on ProgressView forever.
        let newAsset = assets[currentIndex]
        isFavorite = newAsset.isFavorite
        resetPendingEditState()
        Task { await preload(newAsset) }
    }

    private func removeFromAlbum(_ context: AlbumContext, asset: AssetSummary) {
        let targetId = asset.id
        Task {
            do {
                try await service.removeAsset(targetId, fromAlbum: context.id)
                membership.remove([targetId], fromAlbum: context.id)
                removeLocally(assetId: targetId)
            } catch {
                albumActionMessage = "Couldn't remove from “\(context.name)”: \(error)"
            }
        }
    }

    private func removeFromStack(_ asset: AssetSummary, stackId: String) {
        let targetId = asset.id
        isChangingState = true
        Task {
            defer { isChangingState = false }
            do {
                try await service.removeAsset(targetId, fromStack: stackId)
                NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
                // Only the viewer's own list drops it — the photo itself stays in the library.
                guard let index = assets.firstIndex(where: { $0.id == targetId }) else { return }
                assets.remove(at: index)
                if assets.isEmpty { dismiss(); return }
                currentIndex = min(currentIndex, assets.count - 1)
                let newAsset = assets[currentIndex]
                isFavorite = newAsset.isFavorite
                resetPendingEditState()
                await preload(newAsset)
            } catch {
                albumActionMessage = "Couldn't remove from the stack: \(error)"
            }
        }
    }

    private func unstack(_ stackId: String) {
        isChangingState = true
        Task {
            defer { isChangingState = false }
            do {
                try await service.deleteStacks(ids: [stackId])
                NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
                dismiss()
            } catch {
                albumActionMessage = "Couldn't unstack: \(error)"
            }
        }
    }

    private func toggleArchive(_ asset: AssetSummary) {
        let targetId = asset.id
        let archiving = filter != .archive
        isChangingState = true
        Task {
            defer { isChangingState = false }
            do {
                try await service.setArchived(assetIds: [targetId], archived: archiving)
                removeLocally(assetId: targetId)
            } catch {
                albumActionMessage = "Couldn't \(archiving ? "archive" : "unarchive"): \(error)"
            }
        }
    }

    private func restoreAsset(_ asset: AssetSummary) {
        let targetId = asset.id
        isChangingState = true
        Task {
            defer { isChangingState = false }
            do {
                try await service.restoreAssets([targetId])
                removeLocally(assetId: targetId)
            } catch {
                albumActionMessage = "Couldn't restore: \(error)"
            }
        }
    }

    private func deleteAssetPermanently(_ asset: AssetSummary) {
        let targetId = asset.id
        isChangingState = true
        Task {
            defer { isChangingState = false }
            do {
                try await service.deleteAssetsPermanently([targetId])
                removeLocally(assetId: targetId)
            } catch {
                albumActionMessage = "Couldn't delete: \(error)"
            }
        }
    }

    private func deleteAsset(_ asset: AssetSummary) {
        let targetId = asset.id
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await service.trashAsset(assetId: targetId)
                removeLocally(assetId: targetId)
            } catch {
                // Leave the asset in place; the user can retry.
            }
        }
    }
}


/// The viewer's message alerts, kept out of its body so the compiler can type-check it.
private struct ViewerAlerts: ViewModifier {
    @Binding var albumActionMessage: String?
    @Binding var editErrorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert(
                albumActionMessage ?? "",
                isPresented: Binding(get: { albumActionMessage != nil }, set: { if !$0 { albumActionMessage = nil } })
            ) {
                Button("OK") {}
            }
            .alert(
                editErrorMessage ?? "",
                isPresented: Binding(get: { editErrorMessage != nil }, set: { if !$0 { editErrorMessage = nil } })
            ) {
                Button("OK") {}
            }
    }
}
