import SwiftUI

/// Renders a flat list of assets as a justified grid — rows packed edge-to-edge
/// using each photo's real aspect ratio, instead of cropping everything to a square.
struct JustifiedAssetGridView: View {
    let assets: [AssetSummary]
    let service: ImmichService
    @ObservedObject private var zoom = GridZoomStore.shared
    var spacing: CGFloat = 8
    /// Where this section sits among the page's grids (top to bottom), for the arrow keys.
    var order = 0
    var onDelete: ((String) -> Void)? = nil
    /// Set when this grid is showing one specific album's contents, so the viewer can
    /// offer "Remove from Album" in addition to the always-available "Add to Album".
    var albumContext: PhotoViewerView.AlbumContext? = nil
    /// Which slice of the library this grid shows; the trash and archive get their own actions.
    var filter: TimelineFilter = .none

    @State private var containerWidth: CGFloat = 0
    @State private var navigationToken = UUID()
    @EnvironmentObject private var selection: GridSelection
    @EnvironmentObject private var membership: AlbumMembership

    /// Which photo the viewer is open on. Navigation is driven from here rather than by a
    /// `NavigationLink` around each thumbnail because a link (like any button) swallows
    /// the mouse-down, so a photo couldn't be dragged out of it.
    private struct OpenedAsset: Hashable {
        let id: String
        /// When opening a stack: its members, so swiping browses the whole stack.
        var stackAssets: [AssetSummary]? = nil
        var stackId: String? = nil
        var slideshow = false
    }
    @State private var opened: OpenedAsset?

    /// Opens the photo normally; while selecting, a click picks or unpicks it instead.
    @ViewBuilder
    private func cell(for item: (asset: AssetSummary, width: CGFloat), rowHeight: CGFloat) -> some View {
        AssetThumbnailView(
            asset: item.asset,
            request: service.thumbnailRequest(assetId: item.asset.id, isImage: item.asset.isImage),
            size: CGSize(width: item.width, height: rowHeight),
            isSelected: selection.contains(item.asset.id),
            isFocused: selection.focusedId == item.asset.id,
            albumNames: membership.albums(for: item.asset.id, excluding: albumContext?.id).map(\.name),
            isPartnerPhoto: !service.isMine(item.asset)
        )
        .contentShape(Rectangle())
        .id(item.asset.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.description(of: item.asset))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selection.contains(item.asset.id) ? .isSelected : [])
        .accessibilityAction { activate(item.asset) }
        .onTapGesture { activate(item.asset) }
        .onHover { inside in
            if inside {
                // Moving the pointer hands control back to it, but a scroll caused by the
                // arrow keys also slides photos under a still pointer, so ignore that.
                if selection.focusedId != nil, Date().timeIntervalSince(selection.focusSetAt) > 0.6 {
                    selection.focusedId = nil
                }
                selection.hovered = .init(
                    asset: item.asset, filter: filter, neighbors: assets,
                    activate: { activate($0) }
                ) { activate(item.asset) }
                selection.lastFilter = filter
            } else if selection.hovered?.asset.id == item.asset.id {
                selection.hovered = nil
            }
        }
        .draggable(DraggedAssets(
            items: selection.targets(for: item.asset).map { .init(id: $0.id, isImage: $0.isImage) },
            service: service
        ))
    }

    /// A click (or Space/Return over a photo): opens it, or picks/unpicks it while selecting.
    private func activate(_ asset: AssetSummary) {
        if selection.isSelecting {
            selection.toggle(asset)
        } else if let stackId = asset.stackId {
            openStack(stackId, coverId: asset.id)
        } else {
            opened = OpenedAsset(id: asset.id)
        }
    }

    private func openStack(_ stackId: String, coverId: String) {
        Task {
            guard let stack = try? await service.fetchStack(id: stackId) else {
                opened = OpenedAsset(id: coverId)
                return
            }
            let members = AssetSummary.makeSummaries(from: stack.assets)
            opened = OpenedAsset(id: stack.primaryAssetId, stackAssets: members, stackId: stackId)
        }
    }

    private static let spokenDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    /// What VoiceOver reads for a thumbnail, e.g. "Photo, 12 September 2026, favorite".
    static func description(of asset: AssetSummary) -> String {
        var parts = [asset.isImage ? "Photo" : "Video"]
        if asset.livePhotoVideoId != nil { parts.append("Live Photo") }
        if asset.stackCount > 1 { parts.append("stack of \(asset.stackCount)") }
        if let date = asset.date { parts.append(spokenDate.string(from: date)) }
        if asset.isFavorite { parts.append("favorite") }
        return parts.joined(separator: ", ")
    }

    private var layoutSignature: [Double] {
        [Double(assets.count), Double(containerWidth), zoom.value, Double(order), Double(assets.first?.id.hashValue ?? 0), Double(assets.last?.id.hashValue ?? 0)]
    }

    private func registerLayout() {
        let rows = JustifiedLayout.rows(for: assets, containerWidth: containerWidth, targetRowHeight: CGFloat(zoom.value), spacing: spacing)
        selection.register(navigationToken, GridLayoutEntry(
            order: order,
            assets: assets,
            rows: GridNavigator.cells(for: rows, spacing: spacing),
            filter: filter,
            activate: { activate($0) }
        ))
    }

    var body: some View {
        let rows = JustifiedLayout.rows(
            for: assets,
            containerWidth: containerWidth,
            targetRowHeight: CGFloat(zoom.value),
            spacing: spacing
        )

        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let row = rows[rowIndex]
                HStack(spacing: spacing) {
                    ForEach(row.items, id: \.asset.id) { item in
                        cell(for: item, rowHeight: row.height)
                            .contextMenu { GridContextMenu(
                                asset: item.asset, service: service, filter: filter,
                                onSlideshow: { opened = OpenedAsset(id: item.asset.id, slideshow: true) }
                            ) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: layoutSignature) { registerLayout() }
        .onDisappear { selection.unregister(navigationToken) }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { containerWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, newWidth in containerWidth = newWidth }
            }
        )
        .navigationDestination(item: $opened) { open in
            let shown = open.stackAssets ?? assets
            PhotoViewerView(
                assets: shown,
                initialIndex: shown.firstIndex(where: { $0.id == open.id }) ?? 0,
                service: service,
                onDelete: onDelete,
                albumContext: albumContext,
                filter: filter,
                stackId: open.stackId,
                startSlideshow: open.slideshow
            )
        }
    }
}
