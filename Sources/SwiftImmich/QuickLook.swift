import SwiftUI

/// A photo previewed with Space, and the ones around it in the same grid for ← →.
struct QuickLookItem {
    var assets: [AssetSummary]
    var index: Int
    /// Opens the current photo the normal way (Return).
    let activate: (AssetSummary) -> Void

    var current: AssetSummary { assets[index] }
}

/// A large, lightweight preview laid over the window, in the manner of Finder's Quick Look:
/// Space or Esc closes it, ← → step through the neighbouring photos, Return opens the
/// full viewer.
struct QuickLookOverlay: View {
    let service: ImmichService
    let item: QuickLookItem
    var onClose: () -> Void

    @State private var image: NSImage?

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        let asset = item.current
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 12) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 20)
                    } else {
                        ProgressView().controlSize(.large).tint(.white)
                    }
                    if !asset.isImage {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 3) {
                    if let date = asset.date {
                        Text(Self.dateFormat.string(from: date)).font(.callout.weight(.medium))
                    }
                    Text("\(item.index + 1) of \(item.assets.count)  ·  ← → to browse  ·  Space to close  ·  Return to open")
                        .font(.caption)
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
            }
            .padding(40)
            .allowsHitTesting(false)
        }
        .transition(.opacity)
        .task(id: asset.id) { await load(asset) }
    }

    /// The grid's own thumbnail straight away, then the sharper preview when it arrives.
    private func load(_ asset: AssetSummary) async {
        image = nil
        image = await ThumbnailLoader.shared.image(
            for: asset.id, request: service.thumbnailRequest(assetId: asset.id, isImage: asset.isImage)
        )
        if let preview = await ThumbnailLoader.shared.image(
            for: "preview-\(asset.id)", request: service.previewRequest(assetId: asset.id)
        ) {
            if !Task.isCancelled { image = preview }
        }
    }
}

/// Shows Quick Look over the window when the selection hub has an item for it.
struct QuickLookPresenter: ViewModifier {
    let service: ImmichService?
    @ObservedObject var selection: GridSelection

    func body(content: Content) -> some View {
        content
            .overlay {
                if let service, let item = selection.quickLook {
                    QuickLookOverlay(service: service, item: item) { selection.quickLook = nil }
                }
            }
            .animation(Motion.animation(.easeInOut(duration: 0.15)), value: selection.quickLook != nil)
    }
}
