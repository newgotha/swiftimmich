import SwiftUI
import ImmichAPI

struct AlbumsView: View {
    let service: ImmichService
    /// Shared with the sidebar's Albums disclosure group, so creating/deleting an
    /// album here is immediately reflected there too, and vice versa.
    @Binding var albums: [Components.Schemas.AlbumResponseDto]

    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showNewAlbumPrompt = false
    @State private var newAlbumName = ""
    @EnvironmentObject private var gridSelection: GridSelection
    @EnvironmentObject private var transferCenter: TransferCenter
    @State private var dropTargetId: String?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]
    /// Matches PhotoGridView's contentLeadingPadding, so switching sections doesn't
    /// shift the shared left edge between a section's title and its grid content.
    private let contentLeadingPadding: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Albums")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    newAlbumName = ""
                    showNewAlbumPrompt = true
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("New album")
                }
                .padding(.trailing, 16)
            }
            .padding(.leading, contentLeadingPadding)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(AlbumOrder.apply(AlbumOrder.saved, to: albums), id: \.id) { album in
                        NavigationLink {
                            PhotoGridView(service: service, filter: .album(id: album.id, name: album.albumName))
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImageView(
                                    cacheKey: "album-\(album.id)-\(album.albumThumbnailAssetId ?? "")",
                                    request: album.albumThumbnailAssetId.map { service.thumbnailRequest(assetId: $0) }
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                Text(album.albumName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text("\(album.assetCount) items" + (album.shared ? " · Shared" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(HoverCardStyle())
                        .overlay {
                            if dropTargetId == album.id {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .dropDestination(for: DraggedAssets.self) { items, _ in
                            let ids = items.flatMap(\.ids)
                            Task { await gridSelection.add(ids: ids, to: album) }
                            return true
                        } isTargeted: { targeted in
                            if targeted { dropTargetId = album.id } else if dropTargetId == album.id { dropTargetId = nil }
                        }
                        .contextMenu {
                            Button("Share Album…") { gridSelection.pendingShareAlbum = album }
                            Button("Create Share Link…") { gridSelection.pendingShareLink = ShareLinkRequest(title: album.albumName, assetIds: nil, albumId: album.id) }
                            Button("Rename…") { gridSelection.pendingRenameAlbum = album }
                        Button("Edit Description…") { gridSelection.pendingDescribeAlbum = album }
                        Button("Download as Zip…") { if let service = gridSelection.service { transferCenter.downloadAlbum(album, service: service) } }
                            Divider()
                            Button("Delete Album…", role: .destructive) { gridSelection.pendingDeleteAlbum = album }
                        }
                    }
                }
                .padding(.leading, contentLeadingPadding)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading albums…")
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if albums.isEmpty {
                    Text("No albums yet.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("")
        .alert("New Album", isPresented: $showNewAlbumPrompt) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") { createAlbum() }
                .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .task {
            guard albums.isEmpty else { return }
            await loadAlbums()
        }
    }

    private func loadAlbums() async {
        isLoading = true
        defer { isLoading = false }
        do {
            albums = try await service.fetchAlbums()
        } catch {
            errorMessage = "Couldn't load albums: \(error)"
        }
    }

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                let album = try await service.createAlbum(name: name)
                albums.insert(album, at: 0)
            } catch {
                errorMessage = "Couldn't create album: \(error)"
            }
        }
    }
}
