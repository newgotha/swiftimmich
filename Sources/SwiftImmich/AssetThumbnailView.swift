import SwiftUI

struct AssetThumbnailView: View {
    let asset: AssetSummary
    let request: URLRequest
    let size: CGSize
    var isSelected = false
    /// Names of the albums this photo is in; a small badge shows when there are any.
    var albumNames: [String] = []
    /// A photo from someone else's shared library: read-only, marked with a small person icon.
    var isPartnerPhoto = false

    @State private var image: NSImage?
    @State private var isHoveringAlbumBadge = false

    private var albumBadge: some View {
        Image(systemName: "rectangle.stack.fill")
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(4)
            // Stronger than the heart's shadow: on a bright photo (a white wall) a plain
            // white glyph would disappear.
            .shadow(color: .black.opacity(0.75), radius: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .contentShape(Rectangle())
            .onHover { isHoveringAlbumBadge = $0 }
            .popover(isPresented: $isHoveringAlbumBadge, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(albumNames.count == 1 ? "In album" : "In albums")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(albumNames, id: \.self) { name in
                        Label(name, systemImage: "rectangle.stack")
                            .font(.callout)
                    }
                }
                .padding(10)
            }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.gray.opacity(0.15))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }

            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if asset.livePhotoVideoId != nil {
                Image(systemName: "livephoto")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(5)
                    .shadow(color: .black.opacity(0.75), radius: 1.5)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if isPartnerPhoto && !isSelected {
                Image(systemName: "person.crop.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(5)
                    .shadow(color: .black.opacity(0.75), radius: 1.5)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if asset.stackCount > 1 {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text("\(asset.stackCount)")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(4)
                .shadow(color: .black.opacity(0.75), radius: 1.5)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            HStack(spacing: 0) {
                if !albumNames.isEmpty {
                    albumBadge
                }
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .shadow(radius: 2)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: asset.id) {
            image = await ThumbnailLoader.shared.image(for: asset.id, request: request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetEdited)) { note in
            guard (note.object as? String) == asset.id else { return }
            Task { image = await ThumbnailLoader.shared.image(for: asset.id, request: request) }
        }
    }
}
