import SwiftUI

/// A single cover image for a card (album, person, place, memory), loaded through
/// the same authenticated ThumbnailLoader used by the main photo grid.
struct CoverImageView: View {
    let cacheKey: String
    let request: URLRequest?

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(Color.gray.opacity(0.15))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
        }
        .task(id: cacheKey) {
            guard let request else { return }
            image = await ThumbnailLoader.shared.image(for: cacheKey, request: request)
        }
    }
}
