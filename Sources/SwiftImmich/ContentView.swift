import AppKit
import ImmichAPI
import SwiftUI

/// What's currently selected in the sidebar — either one of the fixed sections, or
/// one specific album from the Albums disclosure group.
enum SidebarSelection: Hashable {
    case section(SidebarSection)
    case album(id: String, name: String)
    case mediaType(MediaType)
    case tag(id: String, name: String)
}

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case library, search, favorites, memories, people, places, map, rated, archive, locked, trash, duplicates, storage, sharing, importPhotos, backup, albums

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .search: return "Search"
        case .favorites: return "Favorites"
        case .memories: return "Memories"
        case .people: return "People"
        case .places: return "Places"
        case .archive: return "Archive"
        case .trash: return "Recently Deleted"
        case .duplicates: return "Duplicates"
        case .sharing: return "Sharing"
        case .rated: return "Rated"
        case .locked: return "Locked Folder"
        case .storage: return "Storage"
        case .backup: return "Backup Check"
        case .map: return "Map"
        case .importPhotos: return "Import from Photos"
        case .albums: return "Albums"
        }
    }

    var icon: String {
        switch self {
        case .library: return "photo.on.rectangle"
        case .search: return "magnifyingglass"
        case .favorites: return "heart"
        case .memories: return "sparkles"
        case .people: return "person.crop.square"
        case .places: return "map"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .duplicates: return "square.on.square"
        case .sharing: return "person.2"
        case .rated: return "star"
        case .locked: return "lock"
        case .storage: return "internaldrive"
        case .backup: return "checkmark.shield"
        case .map: return "globe.europe.africa"
        case .importPhotos: return "square.and.arrow.down"
        case .albums: return "square.stack"
        }
    }
}

struct ContentView: View {
    @AppStorage("immichServerURL") private var serverURLString: String = ""
    @AppStorage("immichAPIKey") private var legacyAPIKey: String = ""

    @State private var apiKey: String = ""
    @State private var service: ImmichService?
    @State private var connectionError: String?
    @State private var isConnecting = false
    @State private var selection: SidebarSelection = .section(.library)
    @State private var searchQuery = ""
    @State private var showConnectionPopover = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var albums: [Components.Schemas.AlbumResponseDto] = []
    @State private var renameAlbumText = ""

    @AppStorage("autoUploadEnabled") private var autoUploadEnabled = false
    @AppStorage("autoUploadFolderPath") private var autoUploadFolderPath = ""
    @StateObject private var autoUploadManager = AutoUploadManager()
    // Owned here rather than by the import view so an import keeps running (and its
    // progress survives) while the user browses other sections.
    /// Owned by the App, so the menu bar item can show and control it too.
    @ObservedObject var photosImporter: PhotosImporter
    @StateObject private var viewerTransition = ViewerTransition()
    @StateObject private var gridSelection = GridSelection()
    @StateObject private var albumMembership = AlbumMembership()
    @StateObject private var peopleDirectory = PeopleDirectory()
    @StateObject private var searchModel = SearchModel()
    @StateObject private var lockedSession = LockedFolderSession()
    @StateObject private var transferCenter = TransferCenter()
    @State private var newAlbumName = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: $selection,
                searchQuery: $searchQuery,
                albums: albums,
                importer: photosImporter,
                gridSelection: gridSelection,
                searchModel: searchModel,
                currentUserId: service?.sharing.currentUserId
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            // In the sidebar's own toolbar area, so it sits right beside the sidebar
            // toggle. (When the sidebar is hidden it moves to the detail toolbar below.)
            .toolbar {
                ToolbarItem(placement: .automatic) { connectionButton }
            }
        } detail: {
            if let service {
                NavigationStack {
                    Group {
                        if searchQuery.isEmpty {
                            detailView(for: selection, service: service)
                        } else {
                            SearchResultsView(service: service, query: searchQuery)
                        }
                    }
                    .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search your photos")
                    .background(SearchFieldStyler())
                }
                // Faded in by the swipe-down transition as the photo slides away.
                .opacity(viewerTransition.gridOpacity)
                .toolbar {
                    if columnVisibility == .detailOnly {
                        ToolbarItem(placement: .navigation) { connectionButton }
                    }

                }
            } else if serverURLString.isEmpty || apiKey.isEmpty {
                WelcomeView(
                    serverURL: $serverURLString,
                    apiKey: $apiKey,
                    errorMessage: connectionError,
                    isBusy: isConnecting
                ) { Task { await testAndConnect() } }
                .toolbar {
                    if columnVisibility == .detailOnly {
                        ToolbarItem(placement: .navigation) { connectionButton }
                    }
                }
            } else {
                VStack {
                    if let connectionError {
                        Text(connectionError).foregroundStyle(.red)
                    } else {
                        Text("Connect to a server to load your library.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    if columnVisibility == .detailOnly {
                        ToolbarItem(placement: .navigation) { connectionButton }
                    }
                }
            }
        }
        .environmentObject(viewerTransition)
        .environmentObject(gridSelection)
        .environmentObject(albumMembership)
        .environmentObject(peopleDirectory)
        .environmentObject(searchModel)
        .environmentObject(transferCenter)
        .modifier(WindowExtras(service: service, center: transferCenter, selection: gridSelection, importer: photosImporter, directory: peopleDirectory, locked: lockedSession))
        // Selecting is per-page: a selection made in one section means nothing in another.
        .onChange(of: selection) { _, _ in gridSelection.end(); lockedSession.lock() }
        .onChange(of: searchQuery) { _, _ in gridSelection.end() }
        .onChange(of: albums) { _, newAlbums in gridSelection.albums = newAlbums }
        // The badge map only needs re-reading when albums appear or disappear (photos
        // added/removed by this app update it directly).
        .onChange(of: albums.map(\.id)) { _, _ in
            if let service { albumMembership.rebuild(albums: albums, service: service) }
        }
        // Picks up changes made elsewhere (web UI, another device) when coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let service { albumMembership.rebuildIfStale(albums: albums, service: service) }
        }
        .onAppear {
            gridSelection.membership = albumMembership
            gridSelection.onAlbumUpdated = { updated in
                guard let index = albums.firstIndex(where: { $0.id == updated.id }) else { return }
                albums[index] = updated
                if case .album(let id, _) = selection, id == updated.id {
                    selection = .album(id: id, name: updated.albumName)
                }
            }
            gridSelection.onAlbumDeleted = { id in
                albums.removeAll { $0.id == id }
                if case .album(let selectedId, _) = selection, selectedId == id {
                    selection = .section(.albums)
                }
            }
            gridSelection.onAlbumsChanged = {
                guard let service else { return }
                Task {
                    if let fresh = try? await service.fetchAlbums() { albums = fresh }
                }
            }
            gridSelection.onTagsChanged = {
                guard let service else { return }
                Task {
                    guard let fresh = try? await service.fetchTags() else { return }
                    gridSelection.tags = fresh
                    if case .tag(let id, _) = selection, !fresh.contains(where: { $0.id == id }) {
                        selection = .section(.library)
                    }
                }
            }
            gridSelection.onAlbumCreated = { album in
                if !albums.contains(where: { $0.id == album.id }) { albums.insert(album, at: 0) }
            }
        }
        .onChange(of: gridSelection.pendingRenameAlbum?.id) { _, _ in
            if let album = gridSelection.pendingRenameAlbum { renameAlbumText = album.albumName }
        }
        .modifier(DetailsEditorSheet(service: service, selection: gridSelection))
        .alert("Rename Album", isPresented: Binding(
            get: { gridSelection.pendingRenameAlbum != nil },
            set: { if !$0 { gridSelection.pendingRenameAlbum = nil } }
        )) {
            TextField("Album name", text: $renameAlbumText)
            Button("Rename") {
                guard let album = gridSelection.pendingRenameAlbum else { return }
                gridSelection.pendingRenameAlbum = nil
                let name = renameAlbumText
                Task { await gridSelection.rename(album, to: name) }
            }
            .disabled(renameAlbumText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(gridSelection.pendingDeleteAlbum?.albumName ?? "")”?",
            isPresented: Binding(
                get: { gridSelection.pendingDeleteAlbum != nil },
                set: { if !$0 { gridSelection.pendingDeleteAlbum = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                guard let album = gridSelection.pendingDeleteAlbum else { return }
                gridSelection.pendingDeleteAlbum = nil
                Task { await gridSelection.delete(album) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the album but not the photos in it.")
        }
        .alert("New Album", isPresented: Binding(
            get: { gridSelection.pendingNewAlbum != nil },
            set: { if !$0 { gridSelection.pendingNewAlbum = nil } }
        )) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") {
                let assets = gridSelection.pendingNewAlbum ?? []
                let name = newAlbumName
                newAlbumName = ""
                Task { await gridSelection.createAlbum(named: name, with: assets) }
            }
            .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newAlbumName = "" }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { gridSelection.pendingDelete != nil },
                set: { if !$0 { gridSelection.pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let assets = gridSelection.pendingDelete ?? []
                gridSelection.pendingDelete = nil
                Task { await gridSelection.delete(assets) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be moved to Immich's trash, where they can be recovered.")
        }
        .confirmationDialog(
            permanentDeleteTitle,
            isPresented: Binding(
                get: { gridSelection.pendingPermanentDelete != nil },
                set: { if !$0 { gridSelection.pendingPermanentDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                let assets = gridSelection.pendingPermanentDelete ?? []
                gridSelection.pendingPermanentDelete = nil
                Task { await gridSelection.deletePermanently(assets) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Empty the trash?",
            isPresented: $gridSelection.pendingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                Task { await gridSelection.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in Recently Deleted will be permanently deleted. This can't be undone.")
        }
        .alert(
            gridSelection.message ?? "",
            isPresented: Binding(
                get: { gridSelection.message != nil },
                set: { if !$0 { gridSelection.message = nil } }
            )
        ) {
            Button("OK") {}
        }
        .overlay { ViewerGhostOverlay(transition: viewerTransition) }
        .toolbarBackground(Palette.toolbar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .task { await loadCredentialsAndConnect() }
    }

    private var permanentDeleteTitle: String {
        let count = gridSelection.pendingPermanentDelete?.count ?? 0
        return count == 1 ? "Permanently delete this item?" : "Permanently delete \(count) items?"
    }

    private var deleteTitle: String {
        let count = gridSelection.pendingDelete?.count ?? 0
        return count == 1 ? "Delete this item?" : "Delete \(count) items?"
    }

    private var connectionStatusColor: Color {
        if service != nil { return .green }
        if connectionError != nil { return .red }
        return .secondary
    }

    private var connectionButton: some View {
        Button {
            showConnectionPopover.toggle()
        } label: {
            Image(systemName: "server.rack")
                .accessibilityLabel("Server connection")
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.background, lineWidth: 1))
                }
        }
        .buttonStyle(ToolbarPillStyle())
        .popover(isPresented: $showConnectionPopover) {
            connectionForm
        }
    }

    @ViewBuilder
    private func detailView(for selection: SidebarSelection, service: ImmichService) -> some View {
        switch selection {
        case .section(.library):
            PhotoGridView(service: service)
        case .section(.favorites):
            PhotoGridView(service: service, filter: .favorites)
        case .section(.memories):
            MemoriesView(service: service)
        case .section(.people):
            PeopleView(service: service)
        case .section(.places):
            PlacesView(service: service)
        case .section(.archive):
            PhotoGridView(service: service, filter: .archive)
        case .section(.trash):
            PhotoGridView(service: service, filter: .trash)
        case .section(.duplicates):
            DuplicatesView(service: service)
        case .section(.sharing):
            SharingView(service: service)
        case .section(.search):
            SearchResultsView(service: service, query: searchQuery)
        case .section(.locked):
            LockedFolderView(service: service)
        case .section(.storage):
            StorageView(service: service)
        case .section(.backup):
            BackupCheckView(service: service, importer: photosImporter)
        case .section(.rated):
            RatedView(service: service)
        case .section(.map):
            MapPage(service: service)
        case .tag(let id, let name):
            PhotoGridView(service: service, filter: .tag(id: id, name: name))
                .id(id)
        case .section(.importPhotos):
            PhotosImportView(service: service, importer: photosImporter)
        case .section(.albums):
            AlbumsView(service: service, albums: $albums)
        case .album(let id, let name):
            // Keyed by album: without it, going straight from one album to another
            // reused the first album's grid (its model is created once), so the sidebar
            // said one album while the photos on screen were still the previous one's.
            PhotoGridView(service: service, filter: .album(id: id, name: name))
                .id(id)
        case .mediaType(let type):
            MediaTypeView(service: service, type: type)
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Immich Server")
                .font(.headline)

            TextField("Server URL (https://photos.example.com)", text: $serverURLString)
                .textFieldStyle(.roundedBorder)
            SecureField("API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            if ServerAddress.isInsecureRemote(serverURLString) {
                Label("http:// sends your API key across the internet unencrypted. Use https:// if your server supports it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let connectionError {
                Text(connectionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if service != nil {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("Connect") {
                    connect()
                }
                .disabled(serverURLString.isEmpty || apiKey.isEmpty || isConnecting)
            }

            Divider()

            backgroundUploadSection
        }
        .padding()
        .frame(width: 320)
    }

    private var backgroundUploadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background Upload")
                .font(.headline)

            HStack {
                Text(autoUploadFolderPath.isEmpty ? "No folder selected" : autoUploadFolderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseUploadFolder() }
            }

            Toggle("Watch for new photos", isOn: $autoUploadEnabled)
                .disabled(autoUploadFolderPath.isEmpty || service == nil)
                .onChange(of: autoUploadEnabled) { _, _ in updateAutoUpload() }

            if autoUploadManager.isWatching {
                Label("Watching — \(autoUploadManager.uploadedCount) uploaded", systemImage: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let lastError = autoUploadManager.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func loadCredentialsAndConnect() async {
        if let stored = APIKeyStore.load(), !stored.isEmpty {
            apiKey = stored
        } else if !legacyAPIKey.isEmpty {
            // Migrate a key saved by an earlier build that used @AppStorage (an
            // unencrypted plist) instead of the Keychain, then wipe the old copy.
            apiKey = legacyAPIKey
            APIKeyStore.save(legacyAPIKey)
            legacyAPIKey = ""
        }

        guard service == nil, !serverURLString.isEmpty, !apiKey.isEmpty else { return }
        connect()
    }

    /// First-run connect: proves the address and key work before moving on.
    private func testAndConnect() async {
        connectionError = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            let candidate = try ImmichService(serverURLString: serverURLString, apiKey: apiKey)
            _ = try await candidate.fetchMe()
        } catch {
            connectionError = FriendlyError.message(for: error)
            return
        }
        serverURLString = ServerAddress.normalized(serverURLString)
        connect()
    }

    private func connect() {
        connectionError = nil
        do {
            let newService = try ImmichService(serverURLString: serverURLString, apiKey: apiKey)
            service = newService
            APIKeyStore.save(apiKey)
            legacyAPIKey = ""
            showConnectionPopover = false
            gridSelection.service = newService
            peopleDirectory.invalidate()
            updateAutoUpload()
            Task {
                await newService.refreshSharingState()
                gridSelection.tags = (try? await newService.fetchTags()) ?? []
                if newService.sharing.includePartnerPhotos {
                    NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
                }
                albums = (try? await newService.fetchAlbums()) ?? []
                // Explicit as well as via onChange: reconnecting to the same server
                // leaves the album list unchanged, which wouldn't trigger it.
                albumMembership.rebuild(albums: albums, service: newService)
            }
        } catch {
            connectionError = "Failed to connect: \(error)"
        }
    }

    private func chooseUploadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if url.path != autoUploadFolderPath {
            autoUploadFolderPath = url.path
            autoUploadManager.seedExistingContents(ofFolderAt: url.path)
        }
        updateAutoUpload()
    }

    private func updateAutoUpload() {
        guard autoUploadEnabled, let service, !autoUploadFolderPath.isEmpty else {
            autoUploadManager.stop()
            return
        }
        autoUploadManager.start(folderPath: autoUploadFolderPath, service: service)
    }
}
