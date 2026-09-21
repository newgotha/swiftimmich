import ImmichAPI
import SwiftUI

extension Notification.Name {
    /// Posted (object: `[String]` of asset ids) after assets are moved to trash from a
    /// grid, so whichever grid is showing them can drop them. Grids can't be told
    /// directly: the selection model lives above them, and the timeline's month
    /// sections are created lazily, so only the always-present host can react.
    static let assetsRemoved = Notification.Name("dev.local.swiftimmich.assetsRemoved")
    /// Posted (object: `FavoriteChange`) after assets are favorited or unfavorited.
    static let assetsFavoriteChanged = Notification.Name("dev.local.swiftimmich.assetsFavoriteChanged")
    /// Posted when a grid's contents changed in a way it can't patch locally (stacking
    /// or unstacking), so the visible timeline should reload.
    static let peopleChanged = Notification.Name("dev.local.swiftimmich.peopleChanged")
    static let gridNeedsReload = Notification.Name("dev.local.swiftimmich.gridNeedsReload")
    /// Posted after the trash is emptied, so the Recently Deleted grid can clear itself.
    static let trashEmptied = Notification.Name("dev.local.swiftimmich.trashEmptied")
}

struct FavoriteChange {
    let ids: [String]
    let value: Bool
}

/// Multi-select state shared by every photo grid. It lives above the grids (in
/// ContentView) rather than in any one of them because a selection has to span
/// separate pieces — the timeline is a stack of month sections, each its own grid.
@MainActor
final class GridSelection: ObservableObject {
    @Published var isSelecting = false
    @Published private(set) var selected: [String: AssetSummary] = [:]

    /// Kept in step with ContentView's album list, which the right-click menu offers.
    @Published var albums: [Components.Schemas.AlbumResponseDto] = []
    /// Set to ask ContentView for a name for a new album holding these assets.
    @Published var pendingNewAlbum: [AssetSummary]?
    /// Set to ask ContentView to confirm moving these assets to trash.
    @Published var pendingDelete: [AssetSummary]?
    /// Set to ask ContentView to confirm deleting these assets for good (from the trash).
    @Published var pendingPermanentDelete: [AssetSummary]?
    @Published var pendingEmptyTrash = false
    /// Set to ask ContentView to show the details editor for these assets.
    @Published var pendingEditDetails: [AssetSummary]?
    @Published var tags: [Components.Schemas.TagResponseDto] = []
    /// Set to ask the window for a name for a new tag to apply to these assets.
    @Published var pendingNewTag: [AssetSummary]?
    @Published var pendingDeleteTag: Components.Schemas.TagResponseDto?
    var onTagsChanged: (() -> Void)?
    var toastTask: Task<Void, Never>?
    /// Set to ask the window for the "Who is this?" dialog for a face in the viewer.
    @Published var pendingNameFace: PendingFace?
    /// The photo being previewed with Space, if any.
    @Published var quickLook: QuickLookItem?
    /// Set to ask the window to show comments and likes for an album or one of its photos.
    @Published var pendingActivity: ActivityRequest?
    /// Set to ask the window to show the public-link sheet.
    @Published var pendingShareLink: ShareLinkRequest?
    /// A brief message shown over the window (e.g. "Rated 4 stars").
    @Published var toast: String?
    /// Set to ask the window to show the sharing sheet for this album.
    @Published var pendingShareAlbum: Components.Schemas.AlbumResponseDto?
    /// Set to ask ContentView for a new name for this album.
    @Published var pendingRenameAlbum: Components.Schemas.AlbumResponseDto?
    /// Set to ask ContentView to confirm deleting this album (its photos are kept).
    @Published var pendingDeleteAlbum: Components.Schemas.AlbumResponseDto?
    /// A result or error for ContentView to show.
    @Published var message: String?

    var service: ImmichService?
    /// Set by ContentView; told about album changes so the grid badges update at once.
    weak var membership: AlbumMembership?
    var onAlbumCreated: ((Components.Schemas.AlbumResponseDto) -> Void)?
    var onAlbumUpdated: ((Components.Schemas.AlbumResponseDto) -> Void)?
    var onAlbumDeleted: ((String) -> Void)?
    /// Asks ContentView to re-read the album list, e.g. so item counts stay right.
    var onAlbumsChanged: (() -> Void)?

    var count: Int { selected.count }

    /// Albums you can add photos to (yours, or shared with you as an editor) — the
    /// ones offered by "Add to Album".
    var editableAlbums: [Components.Schemas.AlbumResponseDto] {
        let me = service?.sharing.currentUserId
        return albums.filter { $0.canAddPhotos(userId: me) }
    }

    /// How many photo viewers are on screen; grid shortcuts stand down while one is.
    var openViewers = 0

    /// The thumbnail under the pointer, which is what a bare key press acts on when
    /// nothing is selected. Deliberately not `@Published`: it changes with every mouse
    /// movement and nothing needs to redraw for it.
    struct Hovered {
        let asset: AssetSummary
        let filter: TimelineFilter
        /// The photos around it in the same grid, for Quick Look's arrow keys.
        let neighbors: [AssetSummary]
        let activate: (AssetSummary) -> Void
        let open: () -> Void
    }
    var hovered: Hovered?
    /// The page most recently pointed at, so shortcuts know whether they're in the trash.
    var lastFilter: TimelineFilter = .none

    func contains(_ id: String) -> Bool { selected[id] != nil }

    func toggle(_ asset: AssetSummary) {
        if selected[asset.id] == nil {
            selected[asset.id] = asset
        } else {
            selected[asset.id] = nil
        }
    }

    /// Enters selection mode, optionally with one item already picked.
    func begin(with asset: AssetSummary? = nil) {
        isSelecting = true
        if let asset { selected[asset.id] = asset }
    }

    func deselect(_ ids: [String]) {
        for id in ids { selected[id] = nil }
    }

    func end() {
        isSelecting = false
        selected = [:]
        // A page change or search can leave the last-hovered photo off screen without
        // any "pointer left" ever being reported; make sure a shortcut can't act on it.
        hovered = nil
        quickLook = nil
    }

    /// What a right-click acts on: the whole selection if the clicked item is part of
    /// it, otherwise just the clicked item — right-clicking something you haven't
    /// selected shouldn't silently apply to a pile of other photos.
    func targets(for asset: AssetSummary) -> [AssetSummary] {
        isSelecting && contains(asset.id) ? Array(selected.values) : [asset]
    }

    // MARK: - Album actions

    func add(_ assets: [AssetSummary], to album: Components.Schemas.AlbumResponseDto) async {
        await add(ids: assets.map(\.id), to: album)
    }

    func add(ids: [String], to album: Components.Schemas.AlbumResponseDto) async {
        guard let service, !ids.isEmpty else { return }
        do {
            let result = try await service.addAssets(ids, toAlbum: album.id)
            var parts: [String] = []
            if result.added > 0 { parts.append("Added \(Self.items(result.added)) to “\(album.albumName)”.") }
            if result.alreadyInAlbum > 0 {
                let verb = result.alreadyInAlbum == 1 ? "was" : "were"
                let where_ = result.added == 0 && result.alreadyInAlbum == ids.count ? "in “\(album.albumName)”" : "in it"
                parts.append("\(Self.items(result.alreadyInAlbum)) \(verb) already \(where_).")
            }
            if result.failed > 0 { parts.append("\(Self.items(result.failed)) couldn't be added.") }
            message = parts.joined(separator: " ")
            // Photos that were already in the album count too; only when some failed is
            // the picture uncertain, and the next refresh sorts that out.
            if result.failed == 0 {
                membership?.add(ids, to: .init(id: album.id, name: album.albumName))
            }
            onAlbumsChanged?()
        } catch {
            message = "Couldn't add to “\(album.albumName)”: \(Self.describe(error))"
        }
    }

    func createAlbum(named name: String, with assets: [AssetSummary]) async {
        guard let service else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let album = try await service.createAlbum(name: trimmed, assetIds: assets.map(\.id))
            albums.insert(album, at: 0)
            membership?.add(assets.map(\.id), to: .init(id: album.id, name: album.albumName))
            onAlbumCreated?(album)
            message = "Created “\(album.albumName)” with \(Self.items(assets.count))."
        } catch {
            message = "Couldn't create the album: \(Self.describe(error))"
        }
    }

    func delete(_ assets: [AssetSummary]) async {
        guard let service, !assets.isEmpty else { return }
        do {
            try await service.trashAssets(assets.map(\.id))
            for asset in assets { selected[asset.id] = nil }
            NotificationCenter.default.post(name: .assetsRemoved, object: assets.map(\.id))
        } catch {
            message = "Couldn't delete: \(Self.describe(error))"
        }
    }

    // MARK: - Album management

    func removeFromAlbum(_ assets: [AssetSummary], albumId: String) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.removeAssets(ids, fromAlbum: albumId)
            membership?.remove(ids, fromAlbum: albumId)
            for id in ids { selected[id] = nil }
            NotificationCenter.default.post(name: .assetsRemoved, object: ids)
            onAlbumsChanged?()
        } catch {
            message = "Couldn't remove from the album: \(Self.describe(error))"
        }
    }

    func rename(_ album: Components.Schemas.AlbumResponseDto, to name: String) async {
        guard let service else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != album.albumName else { return }
        do {
            let updated = try await service.updateAlbum(id: album.id, name: trimmed)
            membership?.rename(albumId: album.id, to: updated.albumName)
            onAlbumUpdated?(updated)
        } catch {
            message = "Couldn't rename the album: \(Self.describe(error))"
        }
    }

    func setCover(albumId: String, to asset: AssetSummary) async {
        guard let service else { return }
        do {
            let updated = try await service.updateAlbum(id: albumId, thumbnailAssetId: asset.id)
            onAlbumUpdated?(updated)
            message = "Cover photo updated."
        } catch {
            message = "Couldn't change the cover photo: \(Self.describe(error))"
        }
    }

    func setPersonCover(personId: String, to asset: AssetSummary) async {
        guard let service else { return }
        do {
            _ = try await service.updatePerson(id: personId, featureFaceAssetId: asset.id)
            await ThumbnailLoader.shared.invalidate(assetId: "person-\(personId)")
            NotificationCenter.default.post(name: .peopleChanged, object: personId)
            message = "Cover photo updated."
        } catch {
            message = "Couldn't change the cover photo: \(Self.describe(error))"
        }
    }

    func delete(_ album: Components.Schemas.AlbumResponseDto) async {
        guard let service else { return }
        do {
            try await service.deleteAlbum(id: album.id)
            onAlbumDeleted?(album.id)
        } catch {
            message = "Couldn't delete the album: \(Self.describe(error))"
        }
    }

    // MARK: - Stacks

    func stack(_ assets: [AssetSummary]) async {
        guard let service, assets.count >= 2 else { return }
        // Oldest first: the first photo becomes the stack's cover.
        let ordered = assets.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        do {
            try await service.createStack(assetIds: ordered.map(\.id))
            end()
            NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
        } catch {
            message = "Couldn't stack these: \(Self.describe(error))"
        }
    }

    func unstack(_ assets: [AssetSummary]) async {
        guard let service else { return }
        let stackIds = Array(Set(assets.compactMap(\.stackId)))
        guard !stackIds.isEmpty else { return }
        do {
            try await service.deleteStacks(ids: stackIds)
            end()
            NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
        } catch {
            message = "Couldn't unstack: \(Self.describe(error))"
        }
    }

    // MARK: - Favorite, archive and trash actions

    func setFavorite(_ assets: [AssetSummary], to value: Bool) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.setFavorite(assetIds: ids, isFavorite: value)
            for id in ids { selected[id]?.isFavorite = value }
            NotificationCenter.default.post(name: .assetsFavoriteChanged, object: FavoriteChange(ids: ids, value: value))
        } catch {
            message = "Couldn't \(value ? "favorite" : "unfavorite"): \(Self.describe(error))"
        }
    }

    func setArchived(_ assets: [AssetSummary], to archived: Bool, in filter: TimelineFilter) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.setArchived(assetIds: ids, archived: archived)
            for id in ids { selected[id] = nil }
            // An album shows its photos whether or not they're archived, so only the
            // other grids drop them when they're archived.
            if !(archived && filter.albumId != nil) {
                NotificationCenter.default.post(name: .assetsRemoved, object: ids)
            }
        } catch {
            message = "Couldn't \(archived ? "archive" : "unarchive"): \(Self.describe(error))"
        }
    }

    func restore(_ assets: [AssetSummary]) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.restoreAssets(ids)
            for id in ids { selected[id] = nil }
            NotificationCenter.default.post(name: .assetsRemoved, object: ids)
        } catch {
            message = "Couldn't restore: \(Self.describe(error))"
        }
    }

    func deletePermanently(_ assets: [AssetSummary]) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.deleteAssetsPermanently(ids)
            for id in ids { selected[id] = nil }
            NotificationCenter.default.post(name: .assetsRemoved, object: ids)
        } catch {
            message = "Couldn't delete: \(Self.describe(error))"
        }
    }

    func emptyTrash() async {
        guard let service else { return }
        do {
            try await service.emptyTrash()
            end()
            NotificationCenter.default.post(name: .trashEmptied, object: nil)
        } catch {
            message = "Couldn't empty the trash: \(Self.describe(error))"
        }
    }

    private static func items(_ count: Int) -> String {
        "\(count) \(count == 1 ? "item" : "items")"
    }

    private static func describe(_ error: Error) -> String {
        AppLog.error("action failed", error)
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            return "the server responded \(status)" + (message.map { " — \($0.prefix(200))" } ?? "")
        }
        return error.localizedDescription
    }
}

/// The toolbar's Select / Done control (with a running count while selecting).
struct SelectButton: View {
    @EnvironmentObject private var selection: GridSelection

    var body: some View {
        HStack(spacing: 10) {
            // Always takes up its room (just invisible until something is selected),
            // so the button never moves when the count appears: the count grows into
            // space that was already reserved to the button's left.
            Text("\(selection.count) Selected")
                .font(.callout)
                .foregroundStyle(ToolbarPill.text.opacity(0.7))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)
                .opacity(selection.isSelecting && selection.count > 0 ? 1 : 0)
            Button {
                if selection.isSelecting { selection.end() } else { selection.begin() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: selection.isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                    Text(selection.isSelecting ? "Done" : "Select")
                }
                // Fixed, so the button doesn't shrink when its label changes to "Done".
                .frame(width: 66)
            }
            .buttonStyle(ToolbarPillStyle())
        }
    }
}

/// The Select control plus the count, pinned to the right end of the toolbar just left
/// of the search box. The flexible spacer is what pushes it there — without it the
/// toolbar packs these items up beside the centred All Photos / Months / Years switch.
struct SelectToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) { SelectButton() }
    }
}

/// The right-click menu on a thumbnail. Acts on the selection when the clicked photo is
/// part of it, otherwise on just that photo.
struct GridContextMenu: View {
    let asset: AssetSummary
    let service: ImmichService
    var filter: TimelineFilter = .none
    var onSlideshow: (() -> Void)? = nil

    @EnvironmentObject private var selection: GridSelection
    @EnvironmentObject private var transfers: TransferCenter

    var body: some View {
        let targets = selection.targets(for: asset)
        let noun = targets.count == 1 ? (asset.isImage ? "Photo" : "Video") : "\(targets.count) Items"

        if filter.isTrashed {
            Button {
                Task { await selection.restore(targets) }
            } label: {
                Label("Restore \(noun)", systemImage: "arrow.uturn.backward")
            }

            if !selection.isSelecting {
                Divider()
                Button("Select") { selection.begin(with: asset) }
            }

            Divider()
            Button(role: .destructive) {
                selection.pendingPermanentDelete = targets
            } label: {
                Label("Delete \(noun) Permanently…", systemImage: "trash")
            }
        } else if targets.contains(where: { !service.isMine($0) }) {
            // A partner's photos can be looked at, shared and saved, but not changed.
            ShareLink(
                items: targets.map { SharedAssetFile(service: service, assetId: $0.id, isImage: $0.isImage) },
                preview: { _ in SharePreview(noun) }
            ) {
                Label("Share \(noun)…", systemImage: "square.and.arrow.up")
            }
            Button {
                transfers.download(targets, service: service)
            } label: {
                Label(targets.count == 1 ? "Download Original…" : "Download \(targets.count) Items…", systemImage: "arrow.down.circle")
            }
            if !selection.isSelecting {
                Divider()
                Button("Select") { selection.begin(with: asset) }
            }
        } else {
            ShareLink(
                items: targets.map { SharedAssetFile(service: service, assetId: $0.id, isImage: $0.isImage) },
                preview: { _ in SharePreview(noun) }
            ) {
                Label("Share \(noun)…", systemImage: "square.and.arrow.up")
            }

            Menu {
                ForEach(selection.editableAlbums, id: \.id) { album in
                    Button(album.albumName) {
                        Task { await selection.add(targets, to: album) }
                    }
                }
                if !selection.editableAlbums.isEmpty { Divider() }
                Button("New Album…") { selection.pendingNewAlbum = targets }
            } label: {
                Label("Add \(noun) to Album", systemImage: "rectangle.stack.badge.plus")
            }

            Divider()

            if case let .album(albumId, albumName) = filter {
                Button {
                    Task { await selection.removeFromAlbum(targets, albumId: albumId) }
                } label: {
                    Label("Remove from “\(albumName)”", systemImage: "rectangle.stack.badge.minus")
                }
                if targets.count == 1 {
                    Button {
                        Task { await selection.setCover(albumId: albumId, to: asset) }
                    } label: {
                        Label("Use as Album Cover", systemImage: "photo.on.rectangle")
                    }
                }
                Divider()
            }

            if case let .person(personId, _) = filter, targets.count == 1 {
                Button {
                    Task { await selection.setPersonCover(personId: personId, to: asset) }
                } label: {
                    Label("Use as This Person's Cover", systemImage: "person.crop.circle")
                }
                Divider()
            }

            let allFavorite = targets.allSatisfy(\.isFavorite)
            Button {
                Task { await selection.setFavorite(targets, to: !allFavorite) }
            } label: {
                Label(allFavorite ? "Unfavorite" : "Favorite", systemImage: allFavorite ? "heart.slash" : "heart")
            }

            if filter.isLocked {
                Button {
                    Task { await selection.setLocked(targets, to: false) }
                } label: {
                    Label("Remove from Locked Folder", systemImage: "lock.open")
                }
            } else {
                Button {
                    Task { await selection.setLocked(targets, to: true) }
                } label: {
                    Label("Move to Locked Folder", systemImage: "lock")
                }
            }

            let isArchive = filter == .archive
            Button {
                Task { await selection.setArchived(targets, to: !isArchive, in: filter) }
            } label: {
                Label(isArchive ? "Unarchive" : "Archive", systemImage: isArchive ? "tray.and.arrow.up" : "archivebox")
            }

            Button {
                transfers.download(targets, service: service)
            } label: {
                Label(targets.count == 1 ? "Download Original…" : "Download \(targets.count) Items…", systemImage: "arrow.down.circle")
            }

            if let onSlideshow {
                Button(action: onSlideshow) {
                    Label("Play Slideshow", systemImage: "play.rectangle")
                }
            }

            Button {
                selection.pendingEditDetails = targets
            } label: {
                Label("Edit Date, Location & Description…", systemImage: "calendar.badge.clock")
            }

            RateAndTagMenu(targets: targets, filter: filter)

            Button {
                selection.pendingShareLink = ShareLinkRequest(
                    title: targets.count == 1 ? "1 item" : "\(targets.count) items",
                    assetIds: targets.map(\.id),
                    albumId: nil
                )
            } label: {
                Label("Create Share Link…", systemImage: "link")
            }

            if targets.count >= 2 {
                Button {
                    Task { await selection.stack(targets) }
                } label: {
                    Label("Stack \(targets.count) Items", systemImage: "square.stack.3d.up")
                }
            }
            if targets.contains(where: { $0.stackId != nil }) {
                Button {
                    Task { await selection.unstack(targets) }
                } label: {
                    Label("Unstack", systemImage: "square.stack.3d.up.slash")
                }
            }

            if !selection.isSelecting {
                Divider()
                Button("Select") { selection.begin(with: asset) }
            }

            Divider()
            Button(role: .destructive) {
                selection.pendingDelete = targets
            } label: {
                Label("Delete \(noun)", systemImage: "trash")
            }
        }
    }
}
