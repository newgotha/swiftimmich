import ImmichAPI
import SwiftUI

/// Everything that can sit at the top level of the sidebar: a single page, or a group that
/// expands (Media Types, Saved Searches, Tags, Albums). The user can drag any of them into
/// any order, and the order is remembered.
enum SidebarBlock: String, CaseIterable, Identifiable {
    case library, search, favorites, memories, people, albums, places, map, rated, archive, locked
    case trash, manage, mediaTypes, savedSearches, tags

    var id: String { rawValue }

    /// The single page this row opens, for the ones that are just a page.
    var section: SidebarSection? {
        switch self {
        case .library: return .library
        case .search: return .search
        case .favorites: return .favorites
        case .memories: return .memories
        case .people: return .people
        case .places: return .places
        case .map: return .map
        case .rated: return .rated
        case .archive: return .archive
        case .locked: return .locked
        case .trash: return .trash
        case .albums, .manage, .mediaTypes, .savedSearches, .tags: return nil
        }
    }

    /// How the sidebar is arranged until you drag things around.
    static let defaultOrder: [SidebarBlock] = [
        .library, .search, .favorites, .memories, .people, .albums, .places, .map, .rated,
        .archive, .locked, .trash, .manage, .mediaTypes, .savedSearches, .tags,
    ]

    /// Reads a saved order. Anything unrecognised is dropped, and anything new since it was
    /// saved (a feature added later) is slotted in after the item that precedes it by default.
    static func order(from saved: String) -> [SidebarBlock] {
        var result: [SidebarBlock] = []
        for name in saved.split(separator: ",") {
            if let block = SidebarBlock(rawValue: String(name)), !result.contains(block) { result.append(block) }
        }
        for (index, block) in defaultOrder.enumerated() where !result.contains(block) {
            let before = defaultOrder[..<index].last { result.contains($0) }
            if let before, let position = result.firstIndex(of: before) {
                result.insert(block, at: position + 1)
            } else {
                result.insert(block, at: 0)
            }
        }
        return result
    }

    static func encode(_ order: [SidebarBlock]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}

/// The sidebar list itself.
struct SidebarView: View {
    @Binding var selection: SidebarSelection
    @Binding var searchQuery: String
    let albums: [Components.Schemas.AlbumResponseDto]
    @ObservedObject var importer: PhotosImporter
    @ObservedObject var gridSelection: GridSelection
    @ObservedObject var searchModel: SearchModel
    let currentUserId: String?

    @AppStorage(AlbumSeen.key) private var seenJSON = ""
    @AppStorage(SidebarView.orderKey) private var savedOrder = ""
    @AppStorage("albumsExpanded") private var albumsExpanded = true
    @AppStorage("tagsExpanded") private var tagsExpanded = true
    @AppStorage("mediaTypesExpanded") private var mediaTypesExpanded = true
    @AppStorage("toolsExpanded") private var toolsExpanded = false
    @State private var albumDropTargetId: String?

    static let orderKey = "sidebarOrder"

    /// The blocks actually shown: Saved Searches is hidden until there are some.
    private var visibleBlocks: [SidebarBlock] {
        SidebarBlock.order(from: savedOrder).filter { $0 != .savedSearches || !searchModel.saved.isEmpty }
    }

    var body: some View {
        List(selection: $selection) {
            Color.clear
                .frame(height: 12)
                .listRowBackground(Color.clear)
                .selectionDisabled()

            ForEach(visibleBlocks) { block in
                row(for: block)
            }
            .onMove(perform: move)
        }
        .listStyle(.sidebar)
        // Papers over a persistent hairline "kink" where the toolbar's sidebar
        // boundary sits a couple points off from the actual column divider below
        // it — extends the sidebar's own material up over the seam instead of
        // trying to fix the seam's true position, which several deeper attempts
        // (list style, column width, a from-scratch AppKit split view) couldn't move.
        .background(alignment: .top) {
            Rectangle()
                .fill(Palette.toolbar)
                .frame(height: 48)
                .ignoresSafeArea(edges: .top)
        }
        .contextMenu {
            Button("Reset Sidebar Order") { savedOrder = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showImportPage)) { _ in
            toolsExpanded = true
            selection = .section(.importPhotos)
        }
        .onAppear(perform: recordBaseline)
        .onChange(of: albums.map(\.id)) { _, _ in recordBaseline() }
        .onChange(of: selection) { _, new in
            if case .album(let id, _) = new { markSeen(id) }
        }
    }

    // MARK: - New photos in shared albums

    /// How many photos other people have added to this shared album since it was last opened.
    private func unseenCount(_ album: Components.Schemas.AlbumResponseDto) -> Int {
        guard album.shared, let seen = AlbumSeen.load(seenJSON)[album.id] else { return 0 }
        return max(0, AlbumSeen.othersCount(album, me: currentUserId) - seen)
    }

    /// Albums seen for the first time start as "nothing new", so a fresh install doesn't light up.
    private func recordBaseline() {
        var counts = AlbumSeen.load(seenJSON)
        var changed = false
        for album in albums where counts[album.id] == nil {
            counts[album.id] = AlbumSeen.othersCount(album, me: currentUserId)
            changed = true
        }
        if changed { seenJSON = AlbumSeen.save(counts) }
    }

    private func markSeen(_ albumId: String) {
        guard let album = albums.first(where: { $0.id == albumId }) else { return }
        var counts = AlbumSeen.load(seenJSON)
        counts[albumId] = AlbumSeen.othersCount(album, me: currentUserId)
        seenJSON = AlbumSeen.save(counts)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var order = visibleBlocks
        order.move(fromOffsets: source, toOffset: destination)
        // Blocks that aren't showing (no saved searches yet) keep a place at the end.
        let hidden = SidebarBlock.allCases.filter { !order.contains($0) }
        savedOrder = SidebarBlock.encode(order + hidden)
    }

    @ViewBuilder
    private func row(for block: SidebarBlock) -> some View {
        if let section = block.section {
            HStack {
                Label(section.title, systemImage: section.icon)
                if section == .importPhotos && importer.isRunning {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            .tag(SidebarSelection.section(section))
        } else {
            switch block {
            case .mediaTypes: mediaTypesGroup
            case .manage: toolsGroup
            case .savedSearches:
                SavedSearchesSidebarGroup(model: searchModel) { saved in
                    searchModel.filters = saved.filters
                    searchQuery = saved.query
                    selection = .section(.search)
                }
            case .tags: TagsSidebarGroup(selection: gridSelection, expanded: $tagsExpanded)
            default: albumsGroup
            }
        }
    }

    /// The pages for looking after the library (duplicates, storage, sharing, importing,
    /// backup), kept in one group so the sidebar isn't a long list.
    private static let toolSections: [SidebarSection] = [.duplicates, .storage, .sharing, .importPhotos, .backup]

    private var toolsGroup: some View {
        DisclosureGroup(isExpanded: $toolsExpanded) {
            ForEach(Self.toolSections) { section in
                HStack {
                    Label(section.title, systemImage: section.icon)
                    if section == .importPhotos && importer.isRunning {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
                .tag(SidebarSelection.section(section))
            }
        } label: {
            HStack {
                Label("Library Tools", systemImage: "wrench.and.screwdriver")
                // An import running while the group is closed would otherwise be invisible.
                if importer.isRunning && !toolsExpanded {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var mediaTypesGroup: some View {
        DisclosureGroup(isExpanded: $mediaTypesExpanded) {
            ForEach(MediaType.allCases) { type in
                Label(type.title, systemImage: type.icon)
                    .padding(.vertical, 4)
                    .tag(SidebarSelection.mediaType(type))
            }
        } label: {
            Label("Media Types", systemImage: "square.grid.2x2")
                .padding(.vertical, 4)
        }
    }

    private var albumsGroup: some View {
        DisclosureGroup(isExpanded: $albumsExpanded) {
            ForEach(albums, id: \.id) { album in
                HStack(spacing: 4) {
                    Label(album.albumName, systemImage: "square.stack")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    let unseen = unseenCount(album)
                    if unseen > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .help("\(unseen) new \(unseen == 1 ? "photo" : "photos") from others")
                    }
                    if album.shared {
                        SharedAlbumBadge(album: album, currentUserId: currentUserId, size: .caption)
                    }
                }
                    .padding(.vertical, 2)
                    .background(
                        albumDropTargetId == album.id ? Color.accentColor.opacity(0.3) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .tag(SidebarSelection.album(id: album.id, name: album.albumName))
                    .dropDestination(for: DraggedAssets.self) { items, _ in
                        let ids = items.flatMap(\.ids)
                        Task { await gridSelection.add(ids: ids, to: album) }
                        return true
                    } isTargeted: { targeted in
                        if targeted { albumDropTargetId = album.id } else if albumDropTargetId == album.id { albumDropTargetId = nil }
                    }
                    .contextMenu {
                        Button("Share Album…") { gridSelection.pendingShareAlbum = album }
                        Button("Create Share Link…") {
                            gridSelection.pendingShareLink = ShareLinkRequest(title: album.albumName, assetIds: nil, albumId: album.id)
                        }
                        Button("Rename…") { gridSelection.pendingRenameAlbum = album }
                        Divider()
                        Button("Delete Album…", role: .destructive) { gridSelection.pendingDeleteAlbum = album }
                    }
            }
        } label: {
            Label(SidebarSection.albums.title, systemImage: SidebarSection.albums.icon)
                .padding(.vertical, 4)
                .tag(SidebarSelection.section(.albums))
        }
    }
}
