import SwiftUI

struct AssetThumbnailView: View {
    let asset: AssetSummary
    let request: URLRequest
    let size: CGSize
    var isSelected = false
    /// Highlighted by the arrow keys.
    var isFocused = false
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

    /// The picture and its badges, at the cell's full size.
    private var picture: some View {
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

            if isFocused && !isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 3)
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
    }

    /// A selected photo shrinks a little inside its cell, over a tinted margin, with a check mark,
    /// so it's easy to tell apart from the rest at a glance.
    private static let selectedScale: CGFloat = 0.86

    var body: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
            picture
                .clipShape(RoundedRectangle(cornerRadius: isSelected ? 7 : 0, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: isSelected ? 7 : 0, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                )
                .scaleEffect(isSelected ? Self.selectedScale : 1)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.25), radius: 1.5)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(Motion.animation(.easeOut(duration: 0.16)), value: isSelected)
        .task(id: asset.id) {
            image = await ThumbnailLoader.shared.image(for: asset.id, request: request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetEdited)) { note in
            guard (note.object as? String) == asset.id else { return }
            Task { image = await ThumbnailLoader.shared.image(for: asset.id, request: request) }
        }
    }
}
